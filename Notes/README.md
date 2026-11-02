# Notes

A list of notes kept with Core Data on iOS 6. It's written in SwiftUI with
the CoreData module generated in [../Frameworks](../Frameworks/README.md).

- **Add note** adds a note with a sample title and the current time.
- Opening a note shows its date, a **Done** switch and **Delete**.
- **Delete done** removes the notes marked done.

The notes are saved after every change and stay after the app quits.

```bash
make           # build build/Notes.app
make install   # copy it to the iPod
make run       # launch it (the iPod must be unlocked)
```

## How it works

- **Model in code:** no `.xcdatamodel` is needed. One `NSEntityDescription`,
  `Note`, has three `NSAttributeDescription`s: `title` (string), `created`
  (date) and `done` (boolean).
- **Store:** an `NSPersistentStoreCoordinator` opens a SQLite store, and an
  `NSManagedObjectContext` fetches with an `NSFetchRequest` sorted newest
  first. It inserts with `NSEntityDescription.insertNewObjectForEntityForName`,
  and reads and writes values with key-value coding.
- **Where the store lives:** the app is in `/Applications`, so it isn't
  sandboxed and its folders are the mobile user's. The store is
  `/var/mobile/Library/Notes/Notes.sqlite`. (`/var/mobile/Documents` may not
  be writable by the `mobile` user.)
- **Errors:** `withError` passes an `NSError **` and shows the error's
  description when Core Data reports a failure.
