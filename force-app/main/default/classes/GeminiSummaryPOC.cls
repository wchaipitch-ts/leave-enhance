/**
 * POC: send a single file (PDF / image / audio) to Gemini and log the summary.
 *
 * Runs asynchronously via Queueable so it gets the 12 MB async heap and request-body
 * limits instead of the 6 MB synchronous ones. One file per job. The summary is written
 * to the debug log only -- nothing is persisted.
 *
 * Anonymous Apex:
 *
 *   Id cvId = [SELECT Id FROM ContentVersion WHERE FileExtension = 'pdf' ORDER BY CreatedDate DESC LIMIT 1].Id;
 *   GeminiSummaryPOC.summarizeFileAsync(cvId);
 *
 * Then open the debug log for the async job and search for "GeminiSummaryPOC".
 */
public class GeminiSummaryPOC implements Queueable, Database.AllowsCallouts {

    private static final String API_KEY = 'AQ.Ab8RN6Imwk7zxfvH-h166gJLLJ4fQJ1ho2JHHQgNQkoYWknKfg';
    private static final String MODEL = 'gemini-3.5-flash-lite';
    private static final String ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models/' + MODEL + ':generateContent?key=' + API_KEY;

    private static final String DEFAULT_PROMPT =
        'Summarize the attached file. Respond in plain prose with no markdown formatting. ' +
        'Cover the main topic, the key points, and any notable figures, names or dates. ' +
        'If the file is audio, note who is speaking if that is clear. Keep it under 250 words.';

    /**
     * The raw Blob, its base64 encoding (~1.33x) and the serialized JSON body (~1.33x) are all
     * resident at once, so peak heap runs ~3.7x the file size. Against the 12 MB async heap that
     * puts the safe ceiling near 3 MB. Anything larger needs the Gemini Files API instead of
     * inline_data.
     */
    private static final Integer MAX_FILE_BYTES = 3 * 1024 * 1024;

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
        'aiff' => 'audio/aiff'
    };

    // Queueable state -- one of (contentVersionId) or (fileData + mimeType) is populated.
    private Id contentVersionId;
    private Blob fileData;
    private String mimeType;
    private String prompt;

    public GeminiSummaryPOC(Id contentVersionId, String customPrompt) {
        this.contentVersionId = contentVersionId;
        this.prompt = String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt;
    }

    public GeminiSummaryPOC(Blob fileData, String mimeType, String customPrompt) {
        this.fileData = fileData;
        this.mimeType = mimeType;
        this.prompt = String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt;
    }

    // ==========================================
    // ENTRY POINTS
    // ==========================================

    /** Summarize a Salesforce file. Returns the AsyncApexJob Id. */
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
     * Synchronous core. Callable on its own, but subject to the 6 MB sync heap --
     * prefer the async entry points for anything but the smallest files.
     */
    public static String summarizeBlob(Blob fileData, String mimeType, String customPrompt) {
        return callGemini(fileData, mimeType, String.isBlank(customPrompt) ? DEFAULT_PROMPT : customPrompt).textResponse;
    }

    // ========================================== 
    // ASYNC EXECUTION
    // ==========================================

    public void execute(QueueableContext context) {
        String fileLabel = 'inline bytes';
        try {
            Blob data = this.fileData;
            String resolvedMime = this.mimeType;

            if (data == null) {
                ContentVersion cv = loadContentVersion(this.contentVersionId);
                data = cv.VersionData;
                resolvedMime = resolveMimeType(cv.FileExtension);
                fileLabel = cv.Title + '.' + cv.FileExtension;
            }

            GeminiResult result = callGemini(data, resolvedMime, this.prompt);

            System.debug(LoggingLevel.INFO, '===== GeminiSummaryPOC =====');
            System.debug(LoggingLevel.INFO, 'File     : ' + fileLabel);
            System.debug(LoggingLevel.INFO, 'MIME     : ' + resolvedMime + ' (' + data.size() + ' bytes)');
            System.debug(LoggingLevel.INFO, 'Model    : ' + MODEL);
            System.debug(LoggingLevel.INFO, 'Tokens   : in=' + result.promptTokens + ' out=' + result.completionTokens + ' total=' + result.totalTokens);
            System.debug(LoggingLevel.INFO, 'Summary  :\n' + result.textResponse);
            System.debug(LoggingLevel.INFO, '============================');

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'GeminiSummaryPOC failed for ' + fileLabel +
                ' at line ' + e.getLineNumber() + ': ' + e.getMessage());
        }
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

    // ==========================================
    // CALLOUT
    // ==========================================

    private static GeminiResult callGemini(Blob fileData, String mimeType, String prompt) {
        if (fileData == null) {
            throw new GeminiSummaryException('No file data supplied.');
        }
        if (String.isBlank(mimeType)) {
            throw new GeminiSummaryException('No MIME type resolved for this file.');
        }

        Integer fileBytes = fileData.size();
        if (fileBytes > MAX_FILE_BYTES) {
            throw new GeminiSummaryException('File is ' + fileBytes + ' bytes; this POC caps inline uploads at ' +
                MAX_FILE_BYTES + ' bytes to stay inside the Apex async heap. Use the Gemini Files API for larger files.');
        }

        // parts = [ the file, then the instruction ]
        Map<String, Object> inlineDataMap = new Map<String, Object>{
            'mime_type' => mimeType,
            'data' => EncodingUtil.base64Encode(fileData)
        };
        Map<String, Object> filePart = new Map<String, Object>{ 'inline_data' => inlineDataMap };
        Map<String, Object> textPart = new Map<String, Object>{ 'text' => prompt };

        Map<String, Object> contentMap = new Map<String, Object>{
            'parts' => new List<Object>{ filePart, textPart }
        };
        Map<String, Object> rootPayload = new Map<String, Object>{
            'contents' => new List<Object>{ contentMap }
        };

        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
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
