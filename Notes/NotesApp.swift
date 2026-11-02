import CoreData
import Foundation
import ObjCInterop
import SwiftUI

// Notes kept with Core Data in a SQLite store (Library/Notes/Notes.sqlite),
// so they're still there after the app quits. The data model (one entity,
// Note, with a title, a creation date and a done flag) is built in code,
// with no .xcdatamodel. Everything goes through the CoreData module
// generated from the SDK's headers.

@main
struct NotesApp: App {
    let store = NoteStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                NoteList()
            }
            .environmentObject(store)
        }
    }
}

struct Note: Identifiable {
    /// The NSManagedObject's address.
    let id: UInt
    let title: String
    let created: String
    let done: Bool
}

final class NoteStore: ObservableObject {
    let context: NSManagedObjectContext
    let storePath: String
    var objects: [UInt: NSManagedObject] = [:]
    let formatter = NSDateFormatter()

    @Published var notes: [Note] = []
    @Published var error: String?

    init() {
        context = NSManagedObjectContext()
        let files = NSFileManager.defaultManager()
        // An app in /Applications isn't sandboxed, so its folders are the
        // mobile user's: the store goes in a folder of its own, Library/Notes.
        let library = NSURL(files.URLsForDirectory(5, inDomains: 1).lastObject)  // NSLibraryDirectory, NSUserDomainMask
        let folder = library.URLByAppendingPathComponent("Notes")
        _ = files.createDirectoryAtPath(folder.path ?? "", withIntermediateDirectories: true, attributes: nil, error: ObjC.nil)
        let url = folder.URLByAppendingPathComponent("Notes.sqlite")
        storePath = url.path ?? "?"
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NoteStore.model())
        let failure = withError { coordinator.addPersistentStoreWithType("SQLite", configuration: nil, URL: url, options: nil, error: $0) == nil }
        if let failure { error = "Couldn't open the store: \(failure)" }
        context.persistentStoreCoordinator = coordinator
        formatter.dateStyle = 2  // NSDateFormatterMediumStyle
        formatter.timeStyle = 1  // NSDateFormatterShortStyle
        reload()
    }

    /// The model: entity Note with title (string), created (date) and done (boolean).
    static func model() -> NSManagedObjectModel {
        func attribute(_ name: String, type: Int) -> ObjCValue {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.optional = false
            return attribute.object
        }
        let entity = NSEntityDescription()
        entity.name = "Note"
        entity.managedObjectClassName = "NSManagedObject"
        let properties = NSMutableArray()
        properties.addObject(attribute("title", type: 700))    // NSStringAttributeType
        properties.addObject(attribute("created", type: 900))  // NSDateAttributeType
        properties.addObject(attribute("done", type: 800))     // NSBooleanAttributeType
        entity.properties = properties.as(NSArray.self)
        let model = NSManagedObjectModel()
        model.entities = NSArray.arrayWithObject(entity.object)
        return model
    }

    func reload() {
        let request = NSFetchRequest.fetchRequestWithEntityName("Note")
        request.sortDescriptors = NSArray.arrayWithObject(NSSortDescriptor.sortDescriptorWithKey("created", ascending: false).object)
        objects = [:]
        var found: [Note] = []
        if let results = context.executeFetchRequest(request, error: ObjC.nil) {
            for index in 0..<results.count {
                let object = NSManagedObject(results.objectAtIndex(index))
                let id = UInt(bitPattern: object.object.asObject?.pointer)
                objects[id] = object
                let created = NSDate(object.valueForKey("created"))
                found.append(Note(id: id, title: object.valueForKey("title").asString ?? "?",
                                  created: created.isNil ? "?" : formatter.stringFromDate(created),
                                  done: object.valueForKey("done").asBool ?? false))
            }
        }
        notes = found
    }

    func add() {
        let object = NSEntityDescription.insertNewObjectForEntityForName("Note", inManagedObjectContext: context)
        object.setValue(ObjCValue(NoteStore.titles[notes.count % NoteStore.titles.count]), forKey: "title")
        object.setValue(NSDate.date().object, forKey: "created")
        object.setValue(NSNumber.numberWithBool(false).object, forKey: "done")
        save()
    }

    func setDone(_ note: Note, _ done: Bool) {
        objects[note.id]?.setValue(NSNumber.numberWithBool(done).object, forKey: "done")
        save()
    }

    func delete(_ note: Note) {
        if let object = objects[note.id] { context.deleteObject(object) }
        save()
    }

    func deleteDone() {
        for note in notes where note.done {
            if let object = objects[note.id] { context.deleteObject(object) }
        }
        save()
    }

    func save() {
        if let failure = withError({ !context.save($0) }) { error = "Couldn't save: \(failure)" }
        reload()
    }

    static let titles = ["Buy milk", "Call the bank", "Charge the iPod", "Water the plants", "Back up the 4S",
                         "Read about Core Data", "Try the BLE scanner", "Write a new SwiftUI app"]
}

/// Runs `body` with an NSError ** argument; if it reports failure, returns
/// the error's description.
func withError(_ body: (ObjCValue) -> Bool) -> String? {
    let slot = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 1)
    defer { slot.deallocate() }
    slot.pointee = nil
    guard body(ObjCValue(storage: .pointer(UnsafeMutableRawPointer(slot)))) else { return nil }
    let error = ObjCValue(object: slot.pointee)
    return error.isNil ? "unknown error" : (error.localizedDescription().asString ?? "?")
}

struct NoteList: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        List {
            HStack(spacing: 24) {
                Button("Add note") { store.add() }
                Spacer()
                Button("Delete done") { store.deleteDone() }
            }
            if let error = store.error {
                Text(error)
                    .foregroundColor(.red)
            }
            if store.notes.isEmpty {
                Text("No notes yet")
                    .foregroundColor(.gray)
            }
            ForEach(store.notes) { note in
                NavigationLink(destination: NoteDetail(note: note)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((note.done ? "✓ " : "") + note.title)
                            .font(.headline)
                            .foregroundColor(note.done ? .gray : nil)
                        Text(note.created)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
            }
            Text("\(store.notes.count) notes in \(store.storePath)")
                .font(.footnote)
                .foregroundColor(.gray)
        }
        .navigationTitle("Notes")
    }
}

struct NoteDetail: View {
    @EnvironmentObject var store: NoteStore
    let note: Note

    var body: some View {
        // The note as it is now, which a toggle may have changed.
        let current = store.notes.first { $0.id == note.id } ?? note
        List {
            Text(current.title)
                .font(.headline)
            HStack {
                Text("Created")
                Spacer()
                Text(current.created)
                    .foregroundColor(.gray)
            }
            Toggle("Done", isOn: Binding(get: { current.done }, set: { store.setDone(current, $0) }))
            Button("Delete") { store.delete(current) }
        }
        .navigationTitle("Note")
    }
}
