/**
 * POC: send a single file (PDF / image / audio / video) to Gemini and log the summary.
 *
 * Two transports, chosen automatically by file size:
 *
 *   <= INLINE_MAX_BYTES   one job, file sent as base64 inline_data
 *   >  INLINE_MAX_BYTES   two chained jobs -- Files API upload, then generateContent
 *
 * The chain matters because Apex caps *cumulative* callout time at 120s per transaction.
 * Upload and generate in one job would share that pool; as separate jobs each gets its own.
 * The generate job also holds only a URI, leaving its heap free for the response.
 *
 * The summary is written to the debug log only -- nothing is persisted.
 *
 * Anonymous Apex:
 *
 *   Id cvId = [SELECT Id FROM ContentVersion WHERE FileExtension = 'pdf' ORDER BY CreatedDate DESC LIMIT 1].Id;
 *   GeminiSummaryPOC.summarizeFileAsync(cvId);
 *
 * Then open the debug log for the async job and search for "GeminiSummaryPOC".
 */

/**
 * Direction
 * Audio: 1min/5min/10min - describe token usage for models
 * PDF: 1 page
 * screenshot: 1 image
 * video: 1min
 */

public class GeminiSummaryPOC implements Queueable, Database.AllowsCallouts {

    private static final String API_KEY = 'AQ.Ab8RN6LcH3o-BtxNpKTP3ABiwEf3b9EUavqSeGUSEppnWqRCwQ';
    private static final String MODEL = 'gemini-3.5-flash-lite';
    private static final String BASE_URL = 'https://generativelanguage.googleapis.com';
    private static final String GENERATE_ENDPOINT = BASE_URL + '/v1beta/models/' + MODEL + ':generateContent?key=' + API_KEY;
    private static final String UPLOAD_ENDPOINT = BASE_URL + '/upload/v1beta/files?key=' + API_KEY;

    private static final String DEFAULT_PROMPT =
        'Summarize the attached file. Respond in plain prose with no markdown formatting. ' +
        'Cover the main topic, the key points, and any notable figures, names or dates. ' +
        'If the file is audio, note who is speaking if that is clear. Keep it under 250 words.';

    /**
     * Inline sends the file as base64 inside a JSON body, so the raw Blob, its encoding (~1.33x)
     * and the serialized body (~1.33x) are all resident at once -- roughly 3.7x the file size
     * against a 12 MB async heap. Past this, switch to the Files API, which posts raw bytes.
     */
    private static final Integer INLINE_MAX_BYTES = 3 * 1024 * 1024;

    /**
     * Files API skips base64, so heap is ~2x the file size instead of ~3.7x, but Apex still caps
     * an async HTTP request body at 12 MB. 11 MB leaves room for headers. Note that a file near
     * this size is also near the heap ceiling -- the Blob alone is most of the budget.
     */
    private static final Integer FILES_API_MAX_BYTES = 11 * 1024 * 1024;

    /** Files API keeps uploads for 48h; PROCESSING state is polled by re-enqueueing. */
    private static final Integer MAX_POLL_ATTEMPTS = 5;

    private static final Map<String, String> EXTENSION_TO_MIME = new Map<String, String>{
        // Documents
        'pdf'  => 'application/pdf',
        'txt'  => 'text/plain',
        // Images
        'png'  => 'image/png',
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'heif' => 'image/heif',
        // Audio
        'mp3'  => 'audio/mp3',
        'wav'  => 'audio/wav',
        'm4a'  => 'audio/mp4',
        'aac'  => 'audio/aac',
        'ogg'  => 'audio/ogg',
        'flac' => 'audio/flac',
        'aiff' => 'audio/aiff',
        // Video
        'mp4'  => 'video/mp4',
        'mov'  => 'video/quicktime',
        'webm' => 'video/webm',
        'mpeg' => 'video/mpeg',
        'avi'  => 'video/x-msvideo'
    };

    private static final String PHASE_DISPATCH = 'DISPATCH';
    private static final String PHASE_GENERATE = 'GENERATE';

    // --- job state ---
    private String phase;
    private String prompt;
    private String mimeType;
    private String fileLabel;

    // DISPATCH only
    private Id contentVersionId;
    private Blob fileData;

    // GENERATE only -- deliberately no Blob here, so this job runs with an near-empty heap
    private String fileUri;
    private String fileName;
    private Boolean needsPoll;
    private Integer pollAttempt;

    public GeminiSummaryPOC(Id contentVersionId, String customPrompt) {
        this.phase = PHASE_DISPATCH;
        this.contentVersionId = contentVersionId;
        this.prompt = String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt;
    }

    public GeminiSummaryPOC(Blob fileData, String mimeType, String customPrompt) {
        this.phase = PHASE_DISPATCH;
        this.fileData = fileData;
        this.mimeType = mimeType;
        this.prompt = String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt;
    }

    /** Phase 2 -- generate from an already-uploaded Files API URI. */
    private GeminiSummaryPOC(String fileUri, String fileName, String mimeType, String prompt,
                             String fileLabel, Boolean needsPoll, Integer pollAttempt) {
        this.phase = PHASE_GENERATE;
        this.fileUri = fileUri;
        this.fileName = fileName;
        this.mimeType = mimeType;
        this.prompt = prompt;
        this.fileLabel = fileLabel;
        this.needsPoll = needsPoll;
        this.pollAttempt = pollAttempt;
    }

    // ==========================================
    // ENTRY POINTS
    // ==========================================

    /** Summarize a Salesforce file. Returns the AsyncApexJob Id of the first job in the chain. */
    public static Id summarizeFileAsync(Id contentVersionId) {
        return summarizeFileAsync(contentVersionId, null);
    }

    public static Id summarizeFileAsync(Id contentVersionId, String customPrompt) {
        if (contentVersionId == null) {
            throw new GeminiSummaryException('A ContentVersion Id is required.');
        }
        return System.enqueueJob(new GeminiSummaryPOC(contentVersionId, customPrompt));
    }

    /** Summarize raw bytes that are not (yet) stored as a Salesforce file. */
    public static Id summarizeBlobAsync(Blob fileData, String mimeType, String customPrompt) {
        if (fileData == null) {
            throw new GeminiSummaryException('No file data supplied.');
        }
        if (String.isBlank(mimeType)) {
            throw new GeminiSummaryException('A mimeType is required when passing raw bytes.');
        }
        return System.enqueueJob(new GeminiSummaryPOC(fileData, mimeType, customPrompt));
    }

    /**
     * Synchronous inline summarize. Callable on its own, but subject to the 6 MB sync heap --
     * prefer the async entry points for anything but the smallest files.
     */
    public static String summarizeBlob(Blob fileData, String mimeType, String customPrompt) {
        return generateInline(fileData, mimeType, String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt).textResponse;
    }

    // ==========================================
    // ASYNC EXECUTION
    // ==========================================

    public void execute(QueueableContext context) {
        try {
            if (this.phase == PHASE_GENERATE) {
                runGeneratePhase();
            } else {
                runDispatchPhase();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'GeminiSummaryPOC failed for ' +
                (this.fileLabel == null ? 'file' : this.fileLabel) +
                ' at line ' + e.getLineNumber() + ': ' + e.getMessage());
        }
    }

    /** Load the file, then either summarize inline or upload and chain. */
    private void runDispatchPhase() {
        Blob data = this.fileData;
        String resolvedMime = this.mimeType;
        this.fileLabel = 'inline bytes';

        if (data == null) {
            ContentVersion cv = loadContentVersion(this.contentVersionId);
            data = cv.VersionData;
            resolvedMime = resolveMimeType(cv.FileExtension);
            this.fileLabel = cv.Title + '.' + cv.FileExtension;
        }

        Integer fileBytes = data.size();
        if (fileBytes > FILES_API_MAX_BYTES) {
            throw new GeminiSummaryException('File is ' + fileBytes + ' bytes; Apex caps an async ' +
                'HTTP request body at 12 MB, so ' + FILES_API_MAX_BYTES + ' bytes is the hard ceiling ' +
                'for uploading from Apex at all.');
        }

        if (fileBytes <= INLINE_MAX_BYTES) {
            System.debug(LoggingLevel.INFO, 'GeminiSummaryPOC: ' + fileBytes + ' bytes -> inline transport');
            GeminiResult result = generateInline(data, resolvedMime, this.prompt);
            logResult(this.fileLabel, resolvedMime, fileBytes, 'inline_data', result);
            return;
        }

        System.debug(LoggingLevel.INFO, 'GeminiSummaryPOC: ' + fileBytes + ' bytes -> Files API transport');
        UploadedFile uploaded = uploadToFilesApi(data, resolvedMime, this.fileLabel);

        System.debug(LoggingLevel.INFO, 'GeminiSummaryPOC: uploaded ' + uploaded.uri +
            ' (state=' + uploaded.state + '), chaining generate job');

        System.enqueueJob(new GeminiSummaryPOC(
            uploaded.uri, uploaded.name, resolvedMime, this.prompt, this.fileLabel,
            uploaded.state != 'ACTIVE', 0
        ));
    }

    /** Poll if the upload is still processing, otherwise generate from the file URI. */
    private void runGeneratePhase() {
        if (this.needsPoll == true) {
            if (this.pollAttempt >= MAX_POLL_ATTEMPTS) {
                throw new GeminiSummaryException('File ' + this.fileName + ' was still PROCESSING after ' +
                    MAX_POLL_ATTEMPTS + ' polls. Gemini never finished ingesting it.');
            }
            String state = fetchFileState(this.fileName);
            System.debug(LoggingLevel.INFO, 'GeminiSummaryPOC: poll ' + (this.pollAttempt + 1) +
                ' -> state=' + state);

            if (state == 'FAILED') {
                throw new GeminiSummaryException('Gemini failed to process uploaded file ' + this.fileName);
            }
            if (state != 'ACTIVE') {
                // Re-enqueue instead of sleeping -- Apex has no wait primitive.
                System.enqueueJob(new GeminiSummaryPOC(this.fileUri, this.fileName, this.mimeType,
                    this.prompt, this.fileLabel, true, this.pollAttempt + 1));
                return;
            }
        }

        GeminiResult result = generateFromUri(this.fileUri, this.mimeType, this.prompt);
        logResult(this.fileLabel, this.mimeType, null, 'files_api', result);
    }

    private static ContentVersion loadContentVersion(Id contentVersionId) {
        List<ContentVersion> versions = [
            SELECT Id, Title, FileExtension, ContentSize, VersionData
            FROM ContentVersion
            WHERE Id = :contentVersionId
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new GeminiSummaryException('No ContentVersion found for Id ' + contentVersionId);
        }
        return versions[0];
    }

    private static void logResult(String fileLabel, String mimeType, Integer fileBytes,
                                  String transport, GeminiResult result) {
        System.debug(LoggingLevel.INFO, '===== GeminiSummaryPOC =====');
        System.debug(LoggingLevel.INFO, 'File     : ' + fileLabel);
        System.debug(LoggingLevel.INFO, 'MIME     : ' + mimeType +
            (fileBytes == null ? '' : ' (' + fileBytes + ' bytes)'));
        System.debug(LoggingLevel.INFO, 'Transport: ' + transport);
        System.debug(LoggingLevel.INFO, 'Model    : ' + MODEL);
        System.debug(LoggingLevel.INFO, 'Tokens   : in=' + result.promptTokens +
            ' out=' + result.completionTokens + ' total=' + result.totalTokens);
        System.debug(LoggingLevel.INFO, 'Summary  :\n' + result.textResponse);
        System.debug(LoggingLevel.INFO, '============================');
    }

    // ==========================================
    // FILES API UPLOAD (resumable protocol)
    // ==========================================

    /**
     * Two callouts: "start" returns an upload URL in a response header, then the raw bytes are
     * posted to it. Budgeted at 20s + 90s to stay inside the 120s cumulative callout limit.
     */
    private static UploadedFile uploadToFilesApi(Blob fileData, String mimeType, String displayName) {
        Integer numBytes = fileData.size();

        HttpRequest startReq = new HttpRequest();
        startReq.setEndpoint(UPLOAD_ENDPOINT);
        startReq.setMethod('POST');
        startReq.setHeader('X-Goog-Upload-Protocol', 'resumable');
        startReq.setHeader('X-Goog-Upload-Command', 'start');
        startReq.setHeader('X-Goog-Upload-Header-Content-Length', String.valueOf(numBytes));
        startReq.setHeader('X-Goog-Upload-Header-Content-Type', mimeType);
        startReq.setHeader('Content-Type', 'application/json');
        startReq.setTimeout(20000);
        startReq.setBody(JSON.serialize(new Map<String, Object>{
            'file' => new Map<String, Object>{ 'display_name' => displayName }
        }));

        HttpResponse startRes = new Http().send(startReq);
        if (startRes.getStatusCode() != 200) {
            throw new GeminiSummaryException('Files API start failed with HTTP ' + startRes.getStatusCode() +
                ': ' + startRes.getBody());
        }

        String uploadUrl = findHeader(startRes, 'X-Goog-Upload-URL');
        if (String.isBlank(uploadUrl)) {
            throw new GeminiSummaryException('Files API start returned no X-Goog-Upload-URL header. ' +
                'Headers seen: ' + startRes.getHeaderKeys());
        }

        HttpRequest uploadReq = new HttpRequest();
        uploadReq.setEndpoint(uploadUrl);
        uploadReq.setMethod('POST');
        uploadReq.setHeader('Content-Length', String.valueOf(numBytes));
        uploadReq.setHeader('X-Goog-Upload-Offset', '0');
        uploadReq.setHeader('X-Goog-Upload-Command', 'upload, finalize');
        uploadReq.setTimeout(90000);
        uploadReq.setBodyAsBlob(fileData); // raw bytes -- no base64 inflation

        HttpResponse uploadRes = new Http().send(uploadReq);
        if (uploadRes.getStatusCode() != 200) {
            throw new GeminiSummaryException('Files API upload failed with HTTP ' + uploadRes.getStatusCode() +
                ': ' + uploadRes.getBody());
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(uploadRes.getBody());
        Map<String, Object> file = (Map<String, Object>) body.get('file');
        if (file == null) {
            throw new GeminiSummaryException('Files API upload returned no file object: ' + uploadRes.getBody());
        }

        UploadedFile uploaded = new UploadedFile();
        uploaded.uri = (String) file.get('uri');
        uploaded.name = (String) file.get('name');
        uploaded.state = (String) file.get('state');

        if (String.isBlank(uploaded.uri)) {
            throw new GeminiSummaryException('Files API upload returned no uri: ' + uploadRes.getBody());
        }
        return uploaded;
    }

    private static String fetchFileState(String fileName) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE_URL + '/v1beta/' + fileName + '?key=' + API_KEY);
        req.setMethod('GET');
        req.setTimeout(15000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new GeminiSummaryException('Files API get failed with HTTP ' + res.getStatusCode() +
                ': ' + res.getBody());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('state');
    }

    /** Apex header lookup is case-sensitive; Google's casing is not guaranteed. */
    private static String findHeader(HttpResponse res, String name) {
        for (String key : res.getHeaderKeys()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return res.getHeader(key);
            }
        }
        return null;
    }

    private class UploadedFile {
        String uri;
        String name;
        String state;
    }

    // ==========================================
    // GENERATE CONTENT
    // ==========================================

    private static GeminiResult generateInline(Blob fileData, String mimeType, String prompt) {
        if (fileData == null) {
            throw new GeminiSummaryException('No file data supplied.');
        }
        if (String.isBlank(mimeType)) {
            throw new GeminiSummaryException('No MIME type resolved for this file.');
        }
        Map<String, Object> filePart = new Map<String, Object>{
            'inline_data' => new Map<String, Object>{
                'mime_type' => mimeType,
                'data' => EncodingUtil.base64Encode(fileData)
            }
        };
        return callGenerate(filePart, prompt);
    }

    private static GeminiResult generateFromUri(String fileUri, String mimeType, String prompt) {
        Map<String, Object> filePart = new Map<String, Object>{
            'file_data' => new Map<String, Object>{
                'mime_type' => mimeType,
                'file_uri' => fileUri
            }
        };
        return callGenerate(filePart, prompt);
    }

    private static GeminiResult callGenerate(Map<String, Object> filePart, String prompt) {
        // parts = [ the file, then the instruction ]
        Map<String, Object> rootPayload = new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{
                    'parts' => new List<Object>{
                        filePart,
                        new Map<String, Object>{ 'text' => prompt }
                    }
                }
            }
        };

        HttpRequest request = new HttpRequest();
        request.setEndpoint(GENERATE_ENDPOINT);
        request.setMethod('POST');
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(120000); // files take far longer than plain text prompts
        request.setBody(JSON.serialize(rootPayload));

        HttpResponse response = new Http().send(request);

        if (response.getStatusCode() != 200) {
            throw new GeminiSummaryException('Gemini returned HTTP ' + response.getStatusCode() +
                ' (' + response.getStatus() + '): ' + response.getBody());
        }

        GeminiResult result = parseGeminiResponse(response.getBody());

        if (String.isBlank(result.textResponse)) {
            throw new GeminiSummaryException('Gemini returned no text. finishReason=' + result.finishReason +
                ', blockReason=' + result.blockReason + '. Raw body: ' + response.getBody());
        }
        return result;
    }

    // ==========================================
    // HELPERS
    // ==========================================

    private static String resolveMimeType(String fileExtension) {
        if (String.isBlank(fileExtension)) {
            throw new GeminiSummaryException('File has no extension, so its MIME type cannot be determined.');
        }
        String mime = EXTENSION_TO_MIME.get(fileExtension.toLowerCase());
        if (mime == null) {
            throw new GeminiSummaryException('Unsupported file type ".' + fileExtension + '". Supported: ' +
                String.join(new List<String>(EXTENSION_TO_MIME.keySet()), ', '));
        }
        return mime;
    }

    private static GeminiResult parseGeminiResponse(String jsonResponse) {
        GeminiResult result = new GeminiResult();
        Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);

        List<Object> candidates = (List<Object>) deserialized.get('candidates');
        if (candidates != null && !candidates.isEmpty()) {
            Map<String, Object> firstCandidate = (Map<String, Object>) candidates[0];
            result.finishReason = (String) firstCandidate.get('finishReason');

            Map<String, Object> content = (Map<String, Object>) firstCandidate.get('content');
            if (content != null) {
                List<Object> parts = (List<Object>) content.get('parts');
                if (parts != null && !parts.isEmpty()) {
                    // A long summary can arrive split across several parts
                    List<String> chunks = new List<String>();
                    for (Object part : parts) {
                        Object text = ((Map<String, Object>) part).get('text');
                        if (text != null) {
                            chunks.add(String.valueOf(text));
                        }
                    }
                    result.textResponse = String.join(chunks, '');
                }
            }
        }

        Map<String, Object> feedback = (Map<String, Object>) deserialized.get('promptFeedback');
        if (feedback != null) {
            result.blockReason = (String) feedback.get('blockReason');
        }

        Map<String, Object> usage = (Map<String, Object>) deserialized.get('usageMetadata');
        if (usage != null) {
            result.promptTokens = usage.get('promptTokenCount') != null ? Integer.valueOf(usage.get('promptTokenCount')) : 0;
            result.completionTokens = usage.get('candidatesTokenCount') != null ? Integer.valueOf(usage.get('candidatesTokenCount')) : 0;
            result.totalTokens = usage.get('totalTokenCount') != null ? Integer.valueOf(usage.get('totalTokenCount')) : 0;
        }

        return result;
    }

    public class GeminiResult {
        public String textResponse {get; set;}
        public String finishReason {get; set;}
        public String blockReason {get; set;}
        public Integer promptTokens {get; set;}
        public Integer completionTokens {get; set;}
        public Integer totalTokens {get; set;}
    }

    public class GeminiSummaryException extends Exception {}
}