public without sharing class LeaveReversalService {

    @TestVisible private static Set<Id> manHoursPendingDelete = new Set<Id>();

    public static void restoreBalances(List<ApplicationItem__c> leavingApproved) {
        if (leavingApproved.isEmpty()) {
            return;
        }
        Map<Id, Decimal> giveBackByBalance = new Map<Id, Decimal>();

        for (ApplicationItem__c appl : leavingApproved) {
            Decimal applied = zeroIfNull(appl.Balance_Applied_Days__c);
            if (applied > 0 && appl.Leave_Balance__c != null) {
                giveBackByBalance.put(appl.Leave_Balance__c,
                    zeroIfNull(giveBackByBalance.get(appl.Leave_Balance__c)) + applied);
            }
            // Cleared whether or not a balance was found, so a record can never be
            // reversed twice off the same stamp.
            appl.Balance_Applied_Days__c = null;
            appl.Carry_Over_Days_Used__c = 0;
            appl.Leave_Balance__c = null;
        }
        if (giveBackByBalance.isEmpty()) {
            return;
        }

        List<Leave_Balance__c> toUpdate = new List<Leave_Balance__c>();
        for (Leave_Balance__c bal : [
            SELECT Id, Leave_Type__c, Entitlement_Days__c, Used_Days__c
            FROM Leave_Balance__c WHERE Id IN :giveBackByBalance.keySet()
            FOR UPDATE
        ]) {
            Decimal giveBack = giveBackByBalance.get(bal.Id);
            bal.Used_Days__c = floorAtZero(zeroIfNull(bal.Used_Days__c) - giveBack);

            Leave_Type_Policy__mdt policy = ApplicationItemTriggerLogic.policyFor(bal.Leave_Type__c);
            if (policy != null && policy.Grants_On_Use__c == true) {
                bal.Entitlement_Days__c = floorAtZero(zeroIfNull(bal.Entitlement_Days__c) - giveBack);
            }
            toUpdate.add(bal);
        }
        update toUpdate;
    }

    /** Same arithmetic for a deleted request, which has no in-flight record to clear. */
    public static void restoreBalancesForDeleted(List<ApplicationItem__c> deleted) {
        List<ApplicationItem__c> copies = new List<ApplicationItem__c>();
        for (ApplicationItem__c appl : deleted) {
            copies.add(new ApplicationItem__c(
                Balance_Applied_Days__c = appl.Balance_Applied_Days__c,
                Leave_Balance__c = appl.Leave_Balance__c
            ));
        }
        restoreBalances(copies);
    }

    public static void clearBookings(Set<Id> applIds) {
        if (applIds.isEmpty() && manHoursPendingDelete.isEmpty()) {
            return;
        }
        if (!applIds.isEmpty()) {
            delete [SELECT Id FROM Event WHERE WhatId IN :applIds];
            delete [SELECT Id FROM Man_hour__c WHERE Application_Item__c IN :applIds];
        }
        if (!manHoursPendingDelete.isEmpty()) {
            delete [SELECT Id FROM Man_hour__c WHERE Id IN :manHoursPendingDelete];
            manHoursPendingDelete.clear();
        }
    }

    /** Called in the before-delete context, while the lookup still points somewhere. */
    public static void rememberBookingsOf(List<ApplicationItem__c> aboutToBeDeleted) {
        Set<Id> ids = new Map<Id, ApplicationItem__c>(aboutToBeDeleted).keySet();
        for (Man_hour__c mh : [SELECT Id FROM Man_hour__c WHERE Application_Item__c IN :ids]) {
            manHoursPendingDelete.add(mh.Id);
        }
    }

    public static void promoteUnpaidSiblings(Set<Id> rejectedParentIds) {
        if (rejectedParentIds.isEmpty()) {
            return;
        }
        List<ApplicationItem__c> siblings = [
            SELECT Id, Request_Type__c, Status__c, Term_From__c, Term_To__c, OwnerId,
                   Split_From__c, Split_From__r.Request_Type__c, RecordTypeId, Leave_Days__c,
                   Period_Leave__c
            FROM ApplicationItem__c
            WHERE Split_From__c IN :rejectedParentIds
              AND Status__c NOT IN ('Approved', 'Rejected')
            ORDER BY Split_From__c, Term_From__c
        ];
        if (siblings.isEmpty()) {
            return;
        }

        Map<Id, List<ApplicationItem__c>> byParent = new Map<Id, List<ApplicationItem__c>>();
        for (ApplicationItem__c sib : siblings) {
            if (!byParent.containsKey(sib.Split_From__c)) {
                byParent.put(sib.Split_From__c, new List<ApplicationItem__c>());
            }
            byParent.get(sib.Split_From__c).add(sib);
        }

        List<ApplicationItem__c> keep = new List<ApplicationItem__c>();
        List<ApplicationItem__c> discard = new List<ApplicationItem__c>();

        for (List<ApplicationItem__c> family : byParent.values()) {
            String originalType = family[0].Split_From__r.Request_Type__c;
            /*
             * The parent may itself have been rewritten to a later type in the chain
             * when nothing above it was affordable. Promoting to what the record already
             * is would be a no-op, and with a single survivor there is nothing to merge
             * either, so the family is left as it stands.
             */
            if (String.isBlank(originalType)
                || (family.size() == 1 && originalType.equals(family[0].Request_Type__c))) {
                continue;
            }

            ApplicationItem__c head = family[0];
            Date furthest = endOf(head);
            for (Integer i = 1; i < family.size(); i++) {
                Date candidate = endOf(family[i]);
                if (candidate > furthest) {
                    furthest = candidate;
                }
                discard.add(family[i]);
            }
            head.Request_Type__c = originalType;
            head.Term_To__c = furthest;

            if (family.size() > 1) {
                head.Period_Leave__c = 'All day';
            }
            keep.add(head);
        }

        LeaveSplitService.rebuildFrom(keep, discard);
    }

    private static Date endOf(ApplicationItem__c appl) {
        return appl.Term_To__c == null ? appl.Term_From__c : appl.Term_To__c;
    }

    private static Decimal floorAtZero(Decimal value) {
        return value < 0 ? 0 : value;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}