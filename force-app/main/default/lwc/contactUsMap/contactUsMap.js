import { LightningElement, track  } from 'lwc';

export default class ContactUsMap extends LightningElement {
    @track mapMarkers = [
        {
            location: {
                Latitude: 13.7303509,
                Longitude: 100.568668,
                City: 'Bangkok',
                Country: 'Thailand',
                PostalCode: '10110',
                Street: '662 Emporium Tower, Room No. 91 & 96, Floor 9, Sukhumvit Road, Klongton, Klongtoey'
            },
            title: 'Emporium Tower (Office)',
            description: 'TerraSky Thailand Office'
        }
    ];

    zoomLevel = 17;

    handleMarkerSelect(event) {
        const selectedMarkerValue = event.detail.selectedMarkerValue;
        // Find the marker that was selected (by comparing the value)
        console.log('selectedMarkerValue : ',selectedMarkerValue);
        
        const marker = this.mapMarkers.find(m => m.value === selectedMarkerValue);
        if (marker) {
            const latitude = marker.location.Latitude;
            const longitude = marker.location.Longitude;
            // Build a Google Maps URL using the latitude and longitude.
            const googleMapsUrl = `https://www.google.com/maps/search/?api=1&query=${latitude},${longitude}`;
            // Open the URL in a new browser tab
            window.open(googleMapsUrl, '_blank');
        }
    }
}