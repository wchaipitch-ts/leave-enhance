/**
 * The BA's rules for AI Deal Intelligence, in one place:
 *
 * 1. Filter — which Events are a Minutes of Meeting worth sending to Gemini.
 *    All must hold: a MOM Type, a MOM Subject, a Description of at least the minimum
 *    length, not yet processed, related to an Opportunity. Types, Subjects and the
 *    length come from Program_Constant__mdt so the BA can change them without a deploy.
 *
 * 2. Merge — how one Gemini result lands on the Opportunity without losing what
 *    earlier MOMs found. Gemini only ever sees the current MOM, so a plain overwrite
 *    would let a dull follow-up meeting erase the budget, competitors and every flag.
 *
 *      A  Keep True        checkboxes      once true, stays true
 *      B  Ignore No Data   facts           "No Data" only fills a blank; real data wins;
 *                                          multi-picklists accumulate
 *      C  Always Overwrite score, reason,  latest answer wins — except an empty Reason
 *                          risks           or a non-numeric Score keeps the old value
 *
 * Pure: no SOQL and no DML. The caller queries fields(), calls mergeAnswer() once per MOM
 * (oldest first), and saves the changes. mergeAnswer() also applies them to the record it
 * was given, so a second MOM on the same Opportunity merges onto the first.
 */
public with sharing class DealIntelligenceRules {

    // ======== Filter ========================================================

    @TestVisible private static final String TYPES_KEY      = 'AI_MOM_Types';
    @TestVisible private static final String SUBJECTS_KEY   = 'AI_MOM_Subjects';
    @TestVisible private static final String MIN_LENGTH_KEY = 'AI_MOM_Min_Length';

    @TestVisible private static Set<String> types;
    @TestVisible private static Set<String> subjects;
    @TestVisible private static Integer minLength;

    public static List<Event> qualifying(List<Event> events) {
        List<Event> result = new List<Event>();
        for (Event e : events) {
            if (isMom(e)) {
                result.add(e);
            }
        }
        return result;
    }

    public static Boolean isMom(Event e) {
        loadFilterConfig();
        // An unset list means the config is missing. Nothing qualifies then, because
        // this runs inside the Event trigger and must never stop a rep saving a meeting.
        if (types.isEmpty() || subjects.isEmpty()) {
            return false;
        }
        return e != null
            && e.AI_Processed__c != true
            && e.WhatId != null
            && e.WhatId.getSObjectType() == Opportunity.SObjectType
            && types.contains(normalise(e.Type))
            && subjects.contains(normalise(e.Subject))
            && String.isNotBlank(e.Description)
            && e.Description.trim().length() >= minLength;
    }

    /** The configured Types, as written in the config — for the backfill's SOQL filter. */
    public static List<String> momTypes() {
        return splitList(value(TYPES_KEY), false);
    }

    /** The configured Subjects, as written in the config — for the backfill's SOQL filter. */
    public static List<String> momSubjects() {
        return splitList(valuesStartingWith(SUBJECTS_KEY), false);
    }

    private static void loadFilterConfig() {
        if (types == null) {
            types = new Set<String>(splitList(value(TYPES_KEY), true));
        }
        if (subjects == null) {
            subjects = new Set<String>(splitList(valuesStartingWith(SUBJECTS_KEY), true));
        }
        if (minLength == null) {
            String raw = value(MIN_LENGTH_KEY);
            minLength = (raw != null && raw.trim().isNumeric()) ? Integer.valueOf(raw.trim()) : 100;
        }
    }

    private static String value(String key) {
        Program_Constant__mdt row = Program_Constant__mdt.getInstance(key);
        return row == null ? null : row.Value__c;
    }

    /**
     * Value__c holds 255 characters, and the Subject list is longer, so it is spread
     * over AI_MOM_Subjects, AI_MOM_Subjects_2, ... — every record whose name starts
     * with the key. A longer value is cut silently on deploy, so add a record instead.
     */
    private static String valuesStartingWith(String key) {
        List<String> parts = new List<String>();
        List<String> names = new List<String>(Program_Constant__mdt.getAll().keySet());
        names.sort();
        for (String name : names) {
            if (name.startsWithIgnoreCase(key)) {
                parts.add(Program_Constant__mdt.getInstance(name).Value__c);
            }
        }
        return parts.isEmpty() ? null : String.join(parts, ';');
    }

    // Semicolon separated, because the Subjects themselves contain '-', '/' and '.'.
    private static List<String> splitList(String raw, Boolean normalised) {
        List<String> result = new List<String>();
        if (String.isBlank(raw)) {
            return result;
        }
        for (String part : raw.split(';')) {
            if (String.isNotBlank(part)) {
                result.add(normalised ? normalise(part) : part.trim());
            }
        }
        return result;
    }

    private static String normalise(String s) {
        return s == null ? null : s.trim().toLowerCase();
    }

    // ======== Merge =========================================================

    public static final List<String> FLAG_FIELDS = new List<String>{
        'Competitor_Topic_Mentioned__c',
        'Budget_Topic_Mentioned__c',
        'Decision_Maker_Mentioned__c',
        'Schedule_Topic_Mentioned__c',
        'Comparison_Topic_Mentioned__c',
        'Discount_Request_Mentioned__c',
        'Current_System_Dissatisfaction_Mentioned__c',
        'Demo_Trial_Requested__c',
        'System_Integration_Topic_Mentioned__c',
        'Data_Migration_Topic_Mentioned__c',
        'Target_Scale_Mentioned__c',
        'Approval_Process_Mentioned__c',
        'Compelling_Event_Mentioned__c',
        'Customer_Next_Action_Assigned__c',
        'Our_Sales_Next_Action_Assigned__c',
        'Customer_Asked_Specific_Questions__c',
        'CustomerSpecifiedConditionsOrConstraints__c'
    };

    public static final List<String> FACT_FIELDS = new List<String>{
        'Mentioned_Product_Competitors__c',
        'Mentioned_SI_Competitors__c',
        'Proposed_Products__c',
        'Current_Management_Method__c',
        'Next_Action_Owner__c',
        'Opportunity_Stage__c',
        'Explicit_Initial_Budget__c',
        'Explicit_Running_Budget__c',
        'Explicit_Budget_Unclear_Type__c',
        'Target_Scale_Quantity__c',
        'Expected_Release_Date__c',
        'Expected_Contract_Project_Start_Date__c',
        'Next_Meeting_Date__c'
    };

    public static final String SCORE_FIELD  = 'Customer_Seriousness_Score__c';
    public static final String REASON_FIELD = 'Reason_for_Seriousness_Score__c';
    public static final String RISKS_FIELD  = 'Hidden_Risks_and_Blockers__c';

    /** Every field mergeAnswer() reads. The caller must query all of them. */
    public static List<String> fields() {
        List<String> result = new List<String>(FLAG_FIELDS);
        result.addAll(FACT_FIELDS);
        result.addAll(new List<String>{ SCORE_FIELD, REASON_FIELD, RISKS_FIELD });
        return result;
    }

    @TestVisible private static final String NO_DATA = 'No Data';
    @TestVisible private static final String CANNOT_DETERMINE = 'Cannot Determine';

    // "No Data, null, Cannot Determine, etc." in the BA's words. Compared lower case.
    private static final Set<String> NO_DATA_WORDS = new Set<String>{
        'no data', 'cannot determine', 'null', 'n/a', 'na', 'none', 'unknown', '-'
    };

    private static final Decimal SCORE_MIN = 1;
    private static final Decimal SCORE_MAX = 100;

    // The prompt numbers its keys: "1_Competitor_Topic_Mentioned__c".
    private static final Pattern KEY_PREFIX = Pattern.compile('^\\d+_');

    public class MergeResult {
        /** Field API name → new value, only for fields that actually changed. */
        public Map<String, Object> changes = new Map<String, Object>();
        /** Anything skipped or adjusted, for the log. Not an error. */
        public List<String> warnings = new List<String>();
    }

    public static MergeResult mergeAnswer(Opportunity current, Map<String, Object> aiJson) {
        MergeResult result = new MergeResult();
        Map<String, Object> answers = byFieldName(aiJson == null ? new Map<String, Object>() : aiJson);
        Map<String, Schema.SObjectField> oppFields = Schema.SObjectType.Opportunity.fields.getMap();

        for (String field : fields()) {
            Schema.SObjectField token = oppFields.get(field);
            if (token == null) {
                result.warnings.add(field + ': not on Opportunity, skipped');
                continue;
            }
            if (!answers.containsKey(field.toLowerCase())) {
                result.warnings.add(field + ': missing from the AI answer, kept');
                continue;
            }
            Object answer = answers.get(field.toLowerCase());
            Schema.DescribeFieldResult describe = token.getDescribe();

            Object newValue;
            Boolean write;
            if (FLAG_FIELDS.contains(field)) {
                write = keepTrue(current, field, answer);
                newValue = true;
            } else if (field == SCORE_FIELD) {
                newValue = score(answer, result);
                write = newValue != null;
            } else if (field == REASON_FIELD) {
                newValue = isBlank(answer) ? null : truncate(field, String.valueOf(answer), describe, result);
                write = newValue != null;
            } else if (field == RISKS_FIELD) {
                newValue = answer == null ? null : truncate(field, String.valueOf(answer), describe, result);
                write = true;
            } else if (describe.getType() == Schema.DisplayType.MULTIPICKLIST) {
                newValue = accumulate(current, field, answer, describe, result);
                write = newValue != null;
            } else {
                newValue = ignoreNoData(current, field, answer, describe, result);
                write = newValue != null;
            }

            if (write && current.get(field) != newValue) {
                current.put(field, newValue);
                result.changes.put(field, newValue);
            }
        }
        return result;
    }

    // ---- Rule A -------------------------------------------------------------

    private static Boolean keepTrue(Opportunity current, String field, Object answer) {
        if (current.get(field) == true) {
            return false;
        }
        return answer == true || (answer instanceof String && ((String) answer).trim().equalsIgnoreCase('true'));
    }

    // ---- Rule B -------------------------------------------------------------

    /** Picklist or text. Returns the value to write, or null to leave the field alone. */
    private static Object ignoreNoData(Opportunity current, String field, Object answer,
                                       Schema.DescribeFieldResult describe, MergeResult result) {
        String text = answer == null ? null : String.valueOf(answer).trim();
        Boolean isPicklist = describe.getType() == Schema.DisplayType.PICKLIST;

        if (!isNoData(text) && isPicklist) {
            String valid = matchPicklist(text, describe);
            if (valid == null) {
                result.warnings.add(field + ': "' + text + '" is not a picklist value, treated as No Data');
            }
            text = valid;
        }

        if (isNoData(text)) {
            // No Data only ever fills a blank — it never replaces something we knew.
            return isBlank(current.get(field)) ? noDataValue(describe) : null;
        }
        return isPicklist ? text : truncate(field, text, describe, result);
    }

    /** Multi-picklist. New real values are added to the old ones: SAP + Odoo → SAP;Odoo. */
    private static Object accumulate(Opportunity current, String field, Object answer,
                                     Schema.DescribeFieldResult describe, MergeResult result) {
        List<String> merged = new List<String>();
        String existing = (String) current.get(field);
        if (String.isNotBlank(existing)) {
            for (String v : existing.split(';')) {
                if (!isNoData(v)) {
                    merged.add(v);
                }
            }
        }

        Boolean added = false;
        for (String v : asList(answer)) {
            if (isNoData(v)) {
                continue;
            }
            String valid = matchPicklist(v, describe);
            if (valid == null) {
                result.warnings.add(field + ': "' + v + '" is not a picklist value, dropped');
            } else if (!merged.contains(valid)) {
                merged.add(valid);
                added = true;
            }
        }

        if (merged.isEmpty()) {
            return isBlank(existing) ? noDataValue(describe) : null;
        }
        // Also drops a stale "No Data" once the first real value arrives.
        return (added || existing.contains(NO_DATA)) ? String.join(merged, ';') : null;
    }

    // ---- Rule C -------------------------------------------------------------

    /** The new score, or null when the answer isn't a number and the old one must stay. */
    private static Decimal score(Object answer, MergeResult result) {
        Decimal value;
        if (answer instanceof Decimal) {
            value = (Decimal) answer;
        } else if (answer instanceof Integer || answer instanceof Long || answer instanceof Double) {
            value = Decimal.valueOf(String.valueOf(answer));
        } else if (answer instanceof String) {
            try {
                value = Decimal.valueOf(((String) answer).trim());
            } catch (TypeException e) {
                value = null;
            }
        }
        if (value == null) {
            result.warnings.add(SCORE_FIELD + ': "' + answer + '" is not a number, kept the old score');
            return null;
        }
        if (value < SCORE_MIN || value > SCORE_MAX) {
            result.warnings.add(SCORE_FIELD + ': ' + value + ' is outside 1–100, bounded');
        }
        return Math.max(SCORE_MIN, Math.min(SCORE_MAX, value.setScale(0, RoundingMode.HALF_UP)));
    }

    // ---- Helpers ------------------------------------------------------------

    private static Map<String, Object> byFieldName(Map<String, Object> aiJson) {
        Map<String, Object> result = new Map<String, Object>();
        for (String key : aiJson.keySet()) {
            String field = KEY_PREFIX.matcher(key.trim()).replaceFirst('');
            result.put(field.toLowerCase(), aiJson.get(key));
        }
        return result;
    }

    private static List<String> asList(Object answer) {
        List<String> result = new List<String>();
        if (answer instanceof List<Object>) {
            for (Object o : (List<Object>) answer) {
                if (o != null) {
                    result.add(String.valueOf(o).trim());
                }
            }
        } else if (answer != null) {
            for (String part : String.valueOf(answer).split(';')) {
                result.add(part.trim());
            }
        }
        return result;
    }

    private static String matchPicklist(String value, Schema.DescribeFieldResult describe) {
        for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
            if (entry.isActive() && entry.getValue().equalsIgnoreCase(value)) {
                return entry.getValue();
            }
        }
        return null;
    }

    /** What a blank field gets when the AI found nothing: the field's own "no data" value. */
    private static String noDataValue(Schema.DescribeFieldResult describe) {
        Schema.DisplayType type = describe.getType();
        if (type != Schema.DisplayType.PICKLIST && type != Schema.DisplayType.MULTIPICKLIST) {
            return NO_DATA;
        }
        // Opportunity_Stage__c says "Cannot Determine" where the others say "No Data".
        String value = matchPicklist(NO_DATA, describe);
        return value != null ? value : matchPicklist(CANNOT_DETERMINE, describe);
    }

    private static String truncate(String field, String value, Schema.DescribeFieldResult describe, MergeResult result) {
        Integer max = describe.getLength();
        if (max > 0 && value.length() > max) {
            result.warnings.add(field + ': ' + value.length() + ' characters cut to ' + max);
            return value.left(max);
        }
        return value;
    }

    private static Boolean isNoData(String value) {
        return String.isBlank(value) || NO_DATA_WORDS.contains(value.trim().toLowerCase());
    }

    private static Boolean isBlank(Object value) {
        return value == null || String.isBlank(String.valueOf(value));
    }
}
