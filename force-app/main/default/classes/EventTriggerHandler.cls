public class EventTriggerHandler {
    
    EventTriggerLogic logic = new EventTriggerLogic();

    public void onBeforeUpdate (List<Event> newList) {
        logic.checkApplicationItemPreventEditCalendar(newList, 'edit');
    }

    public void onBeforeDelete (List<Event> oldList) {
        logic.checkApplicationItemPreventEditCalendar(oldList, 'delete');
    }
    
}