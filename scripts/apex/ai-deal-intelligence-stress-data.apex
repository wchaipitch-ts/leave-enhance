// AI Deal Intelligence — stress-test data for the backfill (sandbox only).
//
//   sf apex run --file scripts/apex/ai-deal-intelligence-stress-data.apex --target-org dev5-ts
//
// Creates DEAL_COUNT deals 'AIDI Stress NNN', each with 4 meetings spread over the past year
// that build on each other, plus 1 meeting the filter must skip; and 4 edge-case deals.
// Every meeting is inserted as processed and then unticked: an update, so the real-time
// trigger stays quiet and everything waits for DealIntelligenceJob.runBackfill().
// Each deal's Description says what the backfill should leave behind; check with
// scripts/apex/ai-deal-intelligence-stress-check.apex. Remove with the reset script.
//
// Gemini calls this will cost on the backfill: DEAL_COUNT x 4 + 6. Check the model's free
// daily quota at https://ai.dev/rate-limit first.

Integer DEAL_COUNT = 25;

String stage, confidence;
for (Schema.PicklistEntry p : Opportunity.StageName.getDescribe().getPicklistValues()) { if (p.isActive()) { stage = p.getValue(); break; } }
for (Schema.PicklistEntry p : Opportunity.Your_Win_Confidence__c.getDescribe().getPicklistValues()) { if (p.isActive()) { confidence = p.getValue(); break; } }

List<String> competitors = new List<String>{ 'Microsoft', 'Oracle', 'SAP', 'Odoo', 'kintone', 'Zoho', 'HubSpot', 'Zendesk', 'Bitrix', 'Cloudee' };
List<String> companies = new List<String>{ 'Siam Foods', 'Chao Phraya Logistics', 'Lanna Hotels', 'Andaman Resorts', 'Isan Agro', 'Rattana Plastics', 'Krungthep Clinics', 'Phuket Marine', 'Korat Steel', 'Udon Motors' };

Event mom(Id whatId, String type, String subject, Integer daysAgo, Integer hour, String text) {
    Datetime starts = Datetime.newInstance(Date.today().addDays(-daysAgo), Time.newInstance(hour, 0, 0, 0));
    return new Event(WhatId = whatId, Type = type, Subject = subject, Description = text,
        StartDateTime = starts, EndDateTime = starts.addHours(1), AI_Processed__c = true);
}
Opportunity deal(String name, String expect) {
    return new Opportunity(Name = name, StageName = stage, Your_Win_Confidence__c = confidence,
        CloseDate = Date.today().addMonths(6), Description = expect);
}

// ---- The regular deals ------------------------------------------------------

List<Opportunity> opps = new List<Opportunity>();
for (Integer i = 1; i <= DEAL_COUNT; i++) {
    List<String> mentioned = new List<String>();
    for (Integer k = 0; k < 4; k++) {
        String c = competitors[Math.mod(i + k, competitors.size())];
        if (!mentioned.contains(c)) { mentioned.add(c); }
    }
    opps.add(deal('AIDI Stress ' + String.valueOf(i).leftPad(3, '0'),
        'EXPECT competitors=' + String.join(mentioned, ';') + ' | budgetFrom=meeting 1 | scoreFrom=meeting 4 (positive, high)'));
}

// ---- Edge cases -------------------------------------------------------------

Opportunity longMom    = deal('AIDI Stress Edge - Long MOM', 'EXPECT analysed despite a very long note (~8,000 characters; watch for timeouts)');
Opportunity sameDay    = deal('AIDI Stress Edge - Same Day', 'EXPECT competitors=SAP;Odoo;Zoho | scoreFrom=16:00 meeting (low: customer pauses the project)');
Opportunity unknown    = deal('AIDI Stress Edge - Unknown Values', 'EXPECT no invalid picklist values saved; warnings in AI Analysis Log Details (Partial) or "Others"');
Opportunity thai       = deal('AIDI Stress Edge - Thai', 'EXPECT Thai note analysed; Kreng-jai deferral recognised; low score');
opps.addAll(new List<Opportunity>{ longMom, sameDay, unknown, thai });
insert opps;

// ---- Meetings ---------------------------------------------------------------

List<Event> moms = new List<Event>();
for (Integer i = 0; i < DEAL_COUNT; i++) {
    Opportunity o = opps[i];
    String company = companies[Math.mod(i, companies.size())];
    Integer budget = 1 + Math.mod(i, 5);
    Integer users = 20 + 10 * Math.mod(i, 8);
    Integer running = 30 + 5 * Math.mod(i, 10);
    String c0 = competitors[Math.mod(i + 1, competitors.size())];
    String c1 = competitors[Math.mod(i + 2, competitors.size())];
    String c2 = competitors[Math.mod(i + 3, competitors.size())];
    String c3 = competitors[Math.mod(i + 4, competitors.size())];

    moms.add(mom(o.Id, 'On-site / Visit', 'On-site / Visit - 1. Initial Meeting / Hearing', 300, 10, String.join(new List<String>{
        'Initial meeting with ' + company + ' (Managing Director and Operations Manager).',
        'They manage customers in Excel and paper today and lose track of follow-ups.',
        'They mentioned they also looked at ' + c0 + '.',
        'Implementation budget is around ' + budget + 'M THB, approved by the Managing Director.',
        'Next meeting: requirement workshop next month.'
    }, '\n')));
    moms.add(mom(o.Id, 'Web Meeting', 'Web Meeting - 2. Detailed Hearing / Requirement Check', 200, 14, String.join(new List<String>{
        'Requirement check with the ' + company + ' IT team.',
        'They asked detailed questions about integration with their accounting system and migrating customer data.',
        'They are also evaluating ' + c1 + '.',
        'The Operations Manager said "I will check with my boss" and gave no date. No next meeting was set.'
    }, '\n')));
    moms.add(mom(o.Id, 'Web Meeting', 'Web Meeting - 3. Proposal / Quote Submission', 100, 9, String.join(new List<String>{
        'Proposal presented to ' + company + ': Sales Cloud for about ' + users + ' users.',
        'Running cost around ' + running + 'k THB per month; they asked for a discount.',
        'They compared our price with ' + c2 + '.',
        'Customer will send their final requirements by next week.'
    }, '\n')));
    moms.add(mom(o.Id, 'On-site / Visit', 'On-site / Visit - 3. Proposal / Quote Submission', 10, 15, String.join(new List<String>{
        'Final proposal review with the ' + company + ' Managing Director.',
        'He confirmed they prefer us over ' + c3 + ' and wants the contract to start next quarter, because their current system contract ends then.',
        'Board approval is scheduled for next week; customer will send the signed order form after that.',
        'We will send the final contract draft tomorrow. Next meeting: contract signing on the 25th.'
    }, '\n')));

    // One meeting the filter must skip, a different reason per deal.
    Integer kind = Math.mod(i, 4);
    if (kind == 0) {
        moms.add(mom(o.Id, 'Web Meeting', 'Web Meeting - 2. Detailed Hearing / Requirement Check', 50, 11, 'Sent follow-up email.'));
    } else if (kind == 1) {
        moms.add(mom(o.Id, 'Dinner / Event', 'Dinner / Event - 1. Initial Meeting / Hearing', 50, 19,
            'Dinner with the ' + company + ' team at their annual event. Nice relationship building, no business details discussed tonight at all.'));
    } else if (kind == 2) {
        moms.add(mom(o.Id, 'Web Meeting', 'Web Meeting - 1. Initial Meeting / Hearing', 400, 10,
            'OLDER THAN ONE YEAR. First intro call with ' + company + '; they only asked for brochures and a price range for a CRM.'));
    } else {
        moms.add(mom(o.Id, 'Web Meeting', 'Quick catch-up', 50, 16,
            'Quick catch-up call with ' + company + ' about the timeline; nothing new was decided and no follow-up was agreed by either side.'));
    }
}

List<String> longParts = new List<String>();
for (Integer n = 1; n <= 40; n++) {
    longParts.add('Point ' + n + ': The customer walked through their current order-to-cash process in detail, including how '
        + 'branch staff record visits, how quotations are approved, and where data is re-typed between systems. ');
}
longParts.add('Budget for implementation is about 4M THB. They are also talking to Oracle. Next meeting: 3 November.');
moms.add(mom(longMom.Id, 'On-site / Visit', 'On-site / Visit - 2. Detailed Hearing / Requirement Check', 20, 10, String.join(longParts, '\n')));

moms.add(mom(sameDay.Id, 'Web Meeting', 'Web Meeting - 1. Initial Meeting / Hearing', 5, 9,
    'Morning call: customer is excited, budget about 2M THB, they also looked at SAP. Next meeting this afternoon.'));
moms.add(mom(sameDay.Id, 'Web Meeting', 'Web Meeting - 2. Detailed Hearing / Requirement Check', 5, 13,
    'Midday session: detailed requirements; they mentioned Odoo as a cheaper option. Next meeting at 4 pm.'));
moms.add(mom(sameDay.Id, 'Web Meeting', 'Web Meeting - 3. Proposal / Quote Submission', 5, 16,
    'Afternoon: customer says the project is paused until next year because of a budget freeze; they will also keep Zoho in mind. No next meeting.'));

moms.add(mom(unknown.Id, 'Web Meeting', 'Web Meeting - 1. Initial Meeting / Hearing', 15, 10, String.join(new List<String>{
    'Customer currently uses Monday.com and Notion, and is also considering Salesforce Agentforce and Pipedrive.',
    'Their SI shortlist includes Accenture and Deloitte.',
    'They manage data in Airtable today. Budget roughly 1.2M THB. Next meeting next week.'
}, '\n')));

moms.add(mom(thai.Id, 'On-site / Visit', 'On-site / Visit - 1. Initial Meeting / Hearing', 25, 10, String.join(new List<String>{
    'ผู้เข้าร่วม: คุณประภาส (ผู้จัดการทั่วไป) และทีมขาย 3 คน',
    'ปัจจุบันใช้ระบบ Legacy ที่พัฒนาเองเมื่อ 10 ปีก่อน มีปัญหาบ่อยและไม่มีคนดูแล',
    'คุณประภาสพูดว่า "น่าสนใจมากครับ ขอเอาไปคุยกับทีมก่อนนะครับ" แต่ไม่ได้บอกว่าจะตอบกลับเมื่อไหร่',
    'ยังไม่ได้พูดถึงงบประมาณหรือกำหนดเวลา และลูกค้าไม่ได้ถามคำถามอะไรเลย',
    'ยังไม่ได้นัดประชุมครั้งถัดไป'
}, '\n')));

insert moms;
for (Event e : moms) { e.AI_Processed__c = false; }
update moms;

System.debug('STRESS ' + opps.size() + ' deals, ' + moms.size() + ' meetings (' + (DEAL_COUNT * 4 + 6) + ' should reach Gemini)');
