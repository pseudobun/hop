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
    ])
    func converts(_ query: String, _ value: String, _ unit: String) throws {
        let c = try #require(Converter.convert(query))
        #expect(Converter.format(c.result, locale: Self.posix) == value)
        #expect(c.to == unit)
    }

    @Test(arguments: ["safari", "open in finder", "2+2", "km to kg", "1 to 2", "kp github", "Visual Studio Code"])
    func notConversions(_ query: String) {
        #expect(Converter.convert(query) == nil)
    }
}
