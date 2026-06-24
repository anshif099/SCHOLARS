importScripts('https://www.gstatic.com/firebasejs/10.8.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.8.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyB5EnlNN4K7McAsAev_-g3qcllTHc67GCg',
  appId: '1:727425292908:web:393807034d880028319649',
  messagingSenderId: '727425292908',
  projectId: 'scholars-c23e4',
  authDomain: 'scholars-c23e4.firebaseapp.com',
  databaseURL: 'https://scholars-c23e4-default-rtdb.firebaseio.com',
  storageBucket: 'scholars-c23e4.firebasestorage.app',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Received background message ', payload);

  const data = payload.data || {};
  if (data.type === 'incoming_class_call') {
    const classId = data.classId || '';
    const topic = data.topic || 'Live Class';
    const teacherName = data.teacherName || 'Teacher';
    const startedAt = data.startedAt || '';

    const notificationTitle = 'Class Live: ' + teacherName;
    const notificationOptions = {
      body: 'Live class started on "' + topic + '". Click here to join.',
      icon: '/favicon.png',
      badge: '/favicon.png',
      tag: 'incoming-call-' + classId,
      requireInteraction: true,
      data: {
        classId: classId,
        topic: topic,
        startedAt: startedAt
      }
    };

    return self.registration.showNotification(notificationTitle, notificationOptions);
  }
});

self.addEventListener('notificationclick', function(event) {
  event.notification.close();

  const classId = event.notification.data ? event.notification.data.classId : '';
  const topic = event.notification.data ? event.notification.data.topic : '';

  const urlToOpen = new URL('/?classId=' + encodeURIComponent(classId) + '&topic=' + encodeURIComponent(topic), self.location.origin).href;

  event.waitUntil(
    clients.matchAll({
      type: 'window',
      includeUncontrolled: true
    }).then(function(windowClients) {
      // Find if there is an open window/tab we can focus and navigate
      for (var i = 0; i < windowClients.length; i++) {
        var client = windowClients[i];
        if ('navigate' in client && 'focus' in client) {
          return client.navigate(urlToOpen).then(c => c.focus());
        }
      }
      // If no window is open, open a new one
      if (clients.openWindow) {
        return clients.openWindow(urlToOpen);
      }
    })
  );
});
