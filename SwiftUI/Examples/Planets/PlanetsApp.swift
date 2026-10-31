import SwiftUI

// A list of planets in a NavigationStack, three levels deep: planets, then a
// planet's facts, then its moons. Each level is a UIViewController pushed onto
// one UINavigationController, with the system back button.

@main
struct PlanetsApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                PlanetList()
            }
        }
    }
}

struct Planet: Identifiable {
    let id: Int
    let name: String
    /// Mean distance from the Sun, in tenths of an astronomical unit.
    let distance: Int
    /// Length of a day, in hours.
    let day: Int
    let moons: [String]
}

let planets = [
    Planet(id: 0, name: "Mercury", distance: 4, day: 4223, moons: []),
    Planet(id: 1, name: "Venus", distance: 7, day: 2802, moons: []),
    Planet(id: 2, name: "Earth", distance: 10, day: 24, moons: ["Moon"]),
    Planet(id: 3, name: "Mars", distance: 15, day: 25, moons: ["Phobos", "Deimos"]),
    Planet(id: 4, name: "Jupiter", distance: 52, day: 10, moons: ["Io", "Europa", "Ganymede", "Callisto"]),
    Planet(id: 5, name: "Saturn", distance: 95, day: 11, moons: ["Mimas", "Enceladus", "Tethys", "Dione", "Rhea", "Titan", "Iapetus"]),
    Planet(id: 6, name: "Uranus", distance: 192, day: 17, moons: ["Miranda", "Ariel", "Umbriel", "Titania", "Oberon"]),
    Planet(id: 7, name: "Neptune", distance: 301, day: 16, moons: ["Triton", "Nereid", "Proteus"]),
]

struct PlanetList: View {
    var body: some View {
        List(planets) { planet in
            NavigationLink(destination: PlanetDetail(planet: planet)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(planet.name)
                        .font(.headline)
                    Text("\(tenths(planet.distance)) AU from the Sun")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Planets")
    }
}

struct PlanetDetail: View {
    let planet: Planet

    var body: some View {
        List {
            Text("Distance: \(tenths(planet.distance)) AU")
            Text("Day: \(planet.day) hours")
            if planet.moons.isEmpty {
                Text("No moons")
                    .foregroundColor(.gray)
            } else {
                NavigationLink(destination: MoonList(planet: planet)) {
                    Text("Moons: \(planet.moons.count)")
                }
            }
        }
        .navigationTitle(planet.name)
    }
}

struct MoonList: View {
    let planet: Planet

    var body: some View {
        List {
            ForEach(0..<planet.moons.count) { index in
                Text(planet.moons[index])
            }
        }
        .navigationTitle("\(planet.name)'s Moons")
    }
}

/// Formats a value in tenths, such as 52 as "5.2".
func tenths(_ value: Int) -> String {
    "\(value / 10).\(value % 10)"
}
