import Foundation
import Testing
@testable import hop

struct ConverterTests {
    static let posix = Locale(identifier: "en_US_POSIX")

    @Test(arguments: [
        ("1 sq mile = km2", "2.58998811", "km²"),
        ("1 m2 = ft2", "10.76391042", "ft²"),
        ("734h to mins", "44040", "min"),
        ("1 square mile in square kilometers", "2.58998811", "km²"),
        ("5 km to mi", "3.106855961", "mi"),
        ("12 in to cm", "30.48", "cm"),
        ("6 ft in m", "1.8288", "m"),
        ("100 f in c", "37.77777778", "°C"),
        ("37°C to F", "98.6", "°F"),
        ("0 k to c", "-273.15", "°C"),
        ("1.5 GB to MB", "1500", "MB"),
        ("1 GiB to MiB", "1024", "MiB"),
        ("100 Mb to MB", "12.5", "MB"),
        ("2 days to hours", "48", "h"),
        ("how many minutes in 2 days", "2880", "min"),
        ("90 min to h", "1.5", "h"),
        ("1 year to days", "365.2425", "d"),
        ("2*3 km to m", "6000", "m"),
        ("1,5 l v ml", "1500", "mL"),
        ("1 gal to l", "3.785411784", "L"),
        ("10 kg to lbs", "22.04622622", "lb"),
        ("100 km/h to mph", "62.13711922", "mph"),
        ("1 bar to psi", "14.50377377", "psi"),
        ("1 kwh to kj", "3600", "kJ"),
        ("100 hp to kw", "74.56998716", "kW"),
        ("180 deg to rad", "3.141592654", "rad"),
        ("1 ha to m2", "10000", "m²"),
        ("1 acre to m2", "4046.856422", "m²"),
        ("1 cubic meter to liters", "1000", "L"),
        ("5 l/100km to mpg", "47.04291667", "mpg"),
        ("convert 3 cups to ml", "709.7647095", "mL"),
        ("km to m", "1000", "m"),
        ("1 in in cm", "2.54", "cm"),
        ("1m2=ft2", "10.76391042", "ft²"),
        ("50 mph -> km/h", "80.4672", "km/h"),
        ("1 kn to km/h", "1.852", "km/h"),
        ("1 atm to torr", "760", "Torr"),
        ("100 ks to kw", "73.549875", "kW"),
        ("20 km/l to l/100km", "5", "L/100km"),
        ("1 long ton to kg", "1016.046909", "kg"),
        ("3 tbsp to tsp", "9", "tsp"),
        ("1 lb in oz", "16", "oz"),
        ("2 weeks to days", "14", "d"),
        ("1 mile in km", "1.609344", "km"),
        // No target: the usual counterpart unit
        ("2 min =", "120", "s"),
        ("2 min to", "120", "s"),
        ("2 min in", "120", "s"),
        ("2 min", "120", "s"),
        ("5 km", "3.106855961", "mi"),
        ("30c", "86", "°F"),
        ("10 lbs", "4.5359237", "kg"),
        ("5 in", "12.7", "cm"),
        ("100 mbps", "12.5", "MB/s"),
        // A target typed in part
        ("2 min to se", "120", "s"),
        ("5 km to mil", "3.106855961", "mi"),
        ("100 kg to po", "220.4622622", "lb"),
        // Several parts of one dimension
        ("1h 30min to min", "90", "min"),
        ("1 h 30 min in minutes", "90", "min"),
        ("5 ft 11 in to cm", "180.34", "cm"),
        ("5'11\" to cm", "180.34", "cm"),
        ("6 ft 2 in in cm", "187.96", "cm"),
        ("2 hours and 30 minutes in minutes", "150", "min"),
        ("1h 30min", "90", "min"),
        // Number words and notations
        ("a day in seconds", "86400", "s"),
        ("half an hour in minutes", "30", "min"),
        ("ten km to miles", "6.213711922", "mi"),
        ("1e3 m to km", "1", "km"),
        ("1.5k km to mi", "932.0567884", "mi"),
        // Questions
        ("how many cm is 5 ft", "152.4", "cm"),
        ("how many seconds are in a minute", "60", "s"),
        ("what's 5 ft in cm", "152.4", "cm"),
        ("whats 100 f in c?", "37.77777778", "°C"),
        ("30 degrees c in f", "86", "°F"),
        // Data rates
        ("100 mbps to MB/s", "12.5", "MB/s"),
        ("1 Gbps in MB/s", "125", "MB/s"),
        // Slovenian
        ("koliko minut je 2 uri", "120", "min"),
        ("koliko sekund ima dan", "86400", "s"),
        ("2 uri v minutah", "120", "min"),
        ("5 km v milje", "3.106855961", "mi"),
        ("100 kg v funte", "220.4622622", "lb"),
        ("pol ure v minutah", "30", "min"),
        ("dva dni v urah", "48", "h"),
    ])
    func converts(_ query: String, _ value: String, _ unit: String) throws {
        let c = try #require(Converter.convert(query))
        #expect(Converter.format(c.result, locale: Self.posix) == value)
        #expect(c.to == unit)
    }

    @Test(arguments: ["safari", "open in finder", "2+2", "km to kg", "1 to 2", "kp github", "Visual Studio Code",
                      "km", "day", "10k steps in km", "how many apps"])
    func notConversions(_ query: String) {
        #expect(Converter.convert(query) == nil)
    }

    @Test func implicitTargetIsFlagged() throws {
        #expect(try #require(Converter.convert("2 min")).implicitTarget)
        #expect(try #require(Converter.convert("2 min =")).implicitTarget)
        #expect(try #require(Converter.convert("2 min to s")).implicitTarget == false)
    }

    @Test func everyDefaultTargetExistsInTheSameDimension() {
        for (from, to) in Converter.defaultTargets {
            let a = Converter.unit(symbol: from), b = Converter.unit(symbol: to)
            #expect(a != nil, "unknown source \(from)")
            #expect(b != nil, "unknown target \(to)")
            if let a, let b { #expect(Converter.sameDimension(a.unit, b.unit), "\(from) → \(to)") }
        }
    }
}
