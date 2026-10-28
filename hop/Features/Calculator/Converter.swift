import Foundation

/// Data rates; Foundation has none. Base unit: bits per second.
nonisolated final class UnitDataRate: Dimension, @unchecked Sendable {
    static let bitsPerSecond = UnitDataRate(symbol: "bit/s", converter: UnitConverterLinear(coefficient: 1))
    override class func baseUnit() -> Self { bitsPerSecond as! Self }
}

/// Natural-language unit conversion: "1 sq mile = km2", "1 m2 to ft2", "734h to mins",
/// "how many minutes in 2 days", "100 f in c", "1.5 GiB as MB", "1h 30min to min",
/// "half an hour in s", "koliko minut je 2 uri". Without a target ("2 min =", "5 km")
/// the usual counterpart unit is used; a target typed in part ("to sec", "to mil") is completed.
nonisolated enum Converter {
    struct UnitInfo {
        let unit: Dimension
        let symbol: String
        let name: String
    }

    struct Conversion: Equatable {
        let value: Double
        let result: Double
        let from: String // symbol
        let to: String
        let fromName: String
        let toName: String
        /// No target was typed; `to` is the usual counterpart of `from`.
        var implicitTarget = false
    }

    // MARK: - Unit table

    private static func custom<T: Dimension>(_ type: T.Type, _ symbol: String, _ coefficient: Double) -> T {
        T(symbol: symbol, converter: UnitConverterLinear(coefficient: coefficient))
    }

    /// base = coefficient / value, for consumption ↔ distance-per-volume (L/100km ↔ mpg).
    private final class ReciprocalConverter: UnitConverter, @unchecked Sendable {
        let coefficient: Double
        init(_ coefficient: Double) { self.coefficient = coefficient }
        override func baseUnitValue(fromValue value: Double) -> Double { coefficient / value }
        override func value(fromBaseUnitValue baseUnitValue: Double) -> Double { coefficient / baseUnitValue }
    }

    /// Foundation's built-in statics are private subclasses (`_NSStatic_NSUnitDuration`), so
    /// `type(of:)` can't tell a custom unit's dimension; match on the public class instead.
    private static let dimensions: [Dimension.Type] = [
        UnitLength.self, UnitArea.self, UnitVolume.self, UnitMass.self, UnitDuration.self, UnitSpeed.self,
        UnitTemperature.self, UnitPressure.self, UnitEnergy.self, UnitPower.self, UnitAngle.self,
        UnitFrequency.self, UnitFuelEfficiency.self, UnitInformationStorage.self, UnitDataRate.self,
    ]

    static func sameDimension(_ a: Dimension, _ b: Dimension) -> Bool {
        guard let da = dimensions.firstIndex(where: { a.isKind(of: $0) }) else { return false }
        return b.isKind(of: dimensions[da])
    }

    /// (unit, display symbol, display name, aliases). Aliases are matched after `normalize`.
    private static func entries() -> [(Dimension, String, String, [String])] {
        let day = custom(UnitDuration.self, "d", 86_400)
        let week = custom(UnitDuration.self, "wk", 604_800)
        let month = custom(UnitDuration.self, "mo", 2_629_746) // 1/12 of a Gregorian year
        let year = custom(UnitDuration.self, "yr", 31_556_952)
        let atm = custom(UnitPressure.self, "atm", 101_325)
        let wattHour = custom(UnitEnergy.self, "Wh", 3_600)
        let squareYard = custom(UnitArea.self, "yd²", 0.83612736)
        let squareNauticalMile = custom(UnitArea.self, "nmi²", 3_429_904)
        let cubicYard = custom(UnitVolume.self, "yd³", 764.554857984) // liters
        // Exact definitions; Foundation's own coefficients are rounded to ~6 significant digits.
        let gallon = custom(UnitVolume.self, "gal", 3.785411784)
        let quart = custom(UnitVolume.self, "qt", 0.946352946)
        let pint = custom(UnitVolume.self, "pt", 0.473176473)
        let cup = custom(UnitVolume.self, "cup", 0.2365882365)
        let fluidOunce = custom(UnitVolume.self, "fl oz", 0.0295735295625)
        let tablespoon = custom(UnitVolume.self, "tbsp", 0.01478676478125)
        let teaspoon = custom(UnitVolume.self, "tsp", 0.00492892159375)
        let cubicFoot = custom(UnitVolume.self, "ft³", 28.316846592)
        let cubicInch = custom(UnitVolume.self, "in³", 0.016387064)
        let pound = custom(UnitMass.self, "lb", 0.45359237)
        let ounce = custom(UnitMass.self, "oz", 0.028349523125)
        let stone = custom(UnitMass.self, "st", 6.35029318)
        let shortTon = custom(UnitMass.self, "ton", 907.18474)
        let longTon = custom(UnitMass.self, "long ton", 1016.0469088)
        let kmh = custom(UnitSpeed.self, "km/h", 1 / 3.6)
        let knot = custom(UnitSpeed.self, "kn", 1852.0 / 3600)
        let psi = custom(UnitPressure.self, "psi", 6894.757293168)
        let mmHg = custom(UnitPressure.self, "mmHg", 133.322387415)
        let inHg = custom(UnitPressure.self, "inHg", 3386.388640341)
        let torr = custom(UnitPressure.self, "Torr", 101_325.0 / 760)
        let horsepower = custom(UnitPower.self, "hp", 745.69987158227022)
        let metricHorsepower = custom(UnitPower.self, "PS", 735.49875)
        let btu = custom(UnitEnergy.self, "BTU", 1055.05585262)
        let electronVolt = custom(UnitEnergy.self, "eV", 1.602176634e-19)
        let megajoule = custom(UnitEnergy.self, "MJ", 1e6)
        let mpg = UnitFuelEfficiency(symbol: "mpg", converter: ReciprocalConverter(235.2145833333333))
        let mpgImperial = UnitFuelEfficiency(symbol: "mpg (imp)", converter: ReciprocalConverter(282.4809363318222))
        let kmPerLiter = UnitFuelEfficiency(symbol: "km/L", converter: ReciprocalConverter(100))

        return [
            // Length
            (UnitLength.meters, "m", "Meters", ["m", "meter", "meters", "metre", "metres", "metrov", "metra", "metri", "metrih", "metre"]),
            (UnitLength.kilometers, "km", "Kilometers", ["km", "kms", "kilometer", "kilometers", "kilometre", "kilometres", "kilometrov", "kilometra", "kilometri", "kilometrih", "kilometre"]),
            (UnitLength.centimeters, "cm", "Centimeters", ["cm", "centimeter", "centimeters", "centimetre", "centimetres", "centimetrov", "centimetrih"]),
            (UnitLength.millimeters, "mm", "Millimeters", ["mm", "millimeter", "millimeters", "millimetre", "millimetres", "milimeter", "milimetrov", "milimetrih", "milimetre"]),
            (UnitLength.decimeters, "dm", "Decimeters", ["dm", "decimeter", "decimeters", "decimetre"]),
            (UnitLength.micrometers, "µm", "Micrometers", ["µm", "um", "micrometer", "micrometers", "micron", "microns"]),
            (UnitLength.nanometers, "nm", "Nanometers", ["nm", "nanometer", "nanometers"]),
            (UnitLength.miles, "mi", "Miles", ["mi", "mile", "miles", "milja", "milj", "milje", "miljah"]),
            (UnitLength.yards, "yd", "Yards", ["yd", "yds", "yard", "yards"]),
            (UnitLength.feet, "ft", "Feet", ["ft", "foot", "feet", "'"]),
            (UnitLength.inches, "in", "Inches", ["in", "inch", "inches", "\"", "palec", "palcev", "palcih", "palce"]),
            (UnitLength.nauticalMiles, "nmi", "Nautical Miles", ["nmi", "nautical mile", "nautical miles", "nm mile"]),
            (UnitLength.lightyears, "ly", "Light-years", ["ly", "light year", "light years", "lightyear", "lightyears", "light-year", "light-years"]),
            (UnitLength.astronomicalUnits, "au", "Astronomical Units", ["au", "astronomical unit", "astronomical units"]),

            // Area
            (UnitArea.squareMeters, "m²", "Square Meters", ["m2", "sqm", "square meter", "square meters", "square metre", "square metres", "kvadratni meter", "kvadratnih metrov", "kvadratov"]),
            (UnitArea.squareKilometers, "km²", "Square Kilometers", ["km2", "sqkm", "square kilometer", "square kilometers", "square kilometre", "square kilometres"]),
            (UnitArea.squareCentimeters, "cm²", "Square Centimeters", ["cm2", "square centimeter", "square centimeters"]),
            (UnitArea.squareMillimeters, "mm²", "Square Millimeters", ["mm2", "square millimeter", "square millimeters"]),
            (UnitArea.squareMiles, "mi²", "Square Miles", ["mi2", "mile2", "sqmi", "square mile", "square miles"]),
            (UnitArea.squareFeet, "ft²", "Square Feet", ["ft2", "foot2", "feet2", "sqft", "square foot", "square feet"]),
            (UnitArea.squareInches, "in²", "Square Inches", ["in2", "inch2", "sqin", "square inch", "square inches"]),
            (squareYard, "yd²", "Square Yards", ["yd2", "yard2", "sqyd", "square yard", "square yards"]),
            (UnitArea.hectares, "ha", "Hectares", ["ha", "hectare", "hectares", "hektar", "hektarjev", "hektarov"]),
            (UnitArea.acres, "ac", "Acres", ["ac", "acre", "acres"]),
            (UnitArea.ares, "a", "Ares", ["are", "ares", "ar", "arov"]),
            (squareNauticalMile, "nmi²", "Square Nautical Miles", ["nmi2", "square nautical mile", "square nautical miles"]),

            // Volume
            (UnitVolume.liters, "L", "Liters", ["l", "liter", "liters", "litre", "litres", "litrov", "litra", "litri", "litrih", "litre"]),
            (UnitVolume.milliliters, "mL", "Milliliters", ["ml", "milliliter", "milliliters", "millilitre", "millilitres", "mililiter", "mililitrov", "mililitrih", "mililitre"]),
            (UnitVolume.centiliters, "cL", "Centiliters", ["cl", "centiliter", "centiliters", "centilitre"]),
            (UnitVolume.deciliters, "dL", "Deciliters", ["dl", "deciliter", "deciliters", "decilitre", "decilitrov", "decilitrih"]),
            (UnitVolume.cubicMeters, "m³", "Cubic Meters", ["m3", "cubic meter", "cubic meters", "cubic metre", "cubic metres", "kubik", "kubikov"]),
            (UnitVolume.cubicCentimeters, "cm³", "Cubic Centimeters", ["cm3", "cc", "ccm", "cubic centimeter", "cubic centimeters"]),
            (UnitVolume.cubicMillimeters, "mm³", "Cubic Millimeters", ["mm3", "cubic millimeter", "cubic millimeters"]),
            (UnitVolume.cubicKilometers, "km³", "Cubic Kilometers", ["km3", "cubic kilometer", "cubic kilometers"]),
            (cubicFoot, "ft³", "Cubic Feet", ["ft3", "cuft", "cubic foot", "cubic feet"]),
            (cubicInch, "in³", "Cubic Inches", ["in3", "cuin", "cubic inch", "cubic inches"]),
            (cubicYard, "yd³", "Cubic Yards", ["yd3", "cubic yard", "cubic yards"]),
            (gallon, "gal", "US Gallons", ["gal", "gallon", "gallons", "us gal", "us gallon", "us gallons"]),
            (UnitVolume.imperialGallons, "imp gal", "Imperial Gallons", ["imp gal", "imperial gallon", "imperial gallons", "uk gallon", "uk gallons"]),
            (quart, "qt", "Quarts", ["qt", "quart", "quarts"]),
            (pint, "pt", "Pints", ["pt", "pint", "pints"]),
            (cup, "cup", "Cups", ["cup", "cups"]),
            (fluidOunce, "fl oz", "Fluid Ounces", ["fl oz", "floz", "fluid ounce", "fluid ounces"]),
            (tablespoon, "tbsp", "Tablespoons", ["tbsp", "tablespoon", "tablespoons"]),
            (teaspoon, "tsp", "Teaspoons", ["tsp", "teaspoon", "teaspoons"]),

            // Mass
            (UnitMass.kilograms, "kg", "Kilograms", ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms", "kilogramov", "kilogramih", "kilograme", "kila", "kile", "kil"]),
            (UnitMass.grams, "g", "Grams", ["g", "gr", "gram", "grams", "gramov", "gramih", "grame"]),
            (UnitMass.milligrams, "mg", "Milligrams", ["mg", "milligram", "milligrams", "miligram"]),
            (UnitMass.micrograms, "µg", "Micrograms", ["µg", "ug", "mcg", "microgram", "micrograms"]),
            (UnitMass.metricTons, "t", "Tonnes", ["t", "tonne", "tonnes", "metric ton", "metric tons", "tona", "ton metric"]),
            (shortTon, "ton", "US Tons", ["ton", "tons", "short ton", "short tons", "us ton", "us tons"]),
            (pound, "lb", "Pounds", ["lb", "lbs", "pound", "pounds", "funt", "funtov", "funte", "funtih", "funta"]),
            (ounce, "oz", "Ounces", ["oz", "ounce", "ounces", "unča"]),
            (stone, "st", "Stones", ["st", "stone", "stones"]),
            (UnitMass.carats, "ct", "Carats", ["ct", "carat", "carats", "karat"]),
            (longTon, "long ton", "Long Tons", ["long ton", "long tons", "uk ton", "uk tons", "imperial ton"]),

            // Time
            (UnitDuration.seconds, "s", "Seconds", ["s", "sec", "secs", "second", "seconds", "sekunda", "sekunde", "sekund", "sek", "sekundah"]),
            (UnitDuration.minutes, "min", "Minutes", ["min", "mins", "minute", "minutes", "minuta", "minut", "minutah"]),
            (UnitDuration.hours, "h", "Hours", ["h", "hr", "hrs", "hour", "hours", "ura", "ure", "ur", "uri", "urah", "uro"]),
            (UnitDuration.milliseconds, "ms", "Milliseconds", ["ms", "msec", "millisecond", "milliseconds", "milisekund"]),
            (UnitDuration.microseconds, "µs", "Microseconds", ["µs", "us", "microsecond", "microseconds"]),
            (UnitDuration.nanoseconds, "ns", "Nanoseconds", ["ns", "nanosecond", "nanoseconds"]),
            (day, "d", "Days", ["d", "day", "days", "dan", "dni", "dnevi", "dneva", "dnevov", "dneh", "dnevih"]),
            (week, "wk", "Weeks", ["w", "wk", "wks", "week", "weeks", "teden", "tedna", "tedni", "tednov", "tednih", "tedne"]),
            (month, "mo", "Months", ["mo", "mos", "month", "months", "mesec", "meseca", "meseci", "mesecev", "mesecih", "mesece"]),
            (year, "yr", "Years", ["y", "yr", "yrs", "year", "years", "leto", "leta", "let", "letih"]),

            // Speed
            (kmh, "km/h", "Kilometers per Hour", ["km/h", "kmh", "kph", "kmph", "km per hour", "kilometers per hour", "kilometres per hour", "km/uro", "kilometrov na uro"]),
            (UnitSpeed.metersPerSecond, "m/s", "Meters per Second", ["m/s", "mps", "meters per second", "metres per second"]),
            (UnitSpeed.milesPerHour, "mph", "Miles per Hour", ["mph", "mi/h", "miles per hour", "mile per hour"]),
            (knot, "kn", "Knots", ["kn", "kt", "kts", "knot", "knots", "vozel", "vozlov"]),
            (custom(UnitSpeed.self, "ft/s", 0.3048), "ft/s", "Feet per Second", ["ft/s", "fps", "feet per second"]),

            // Temperature
            (UnitTemperature.celsius, "°C", "Celsius", ["c", "°c", "celsius", "degc", "degrees celsius", "degree celsius", "degrees c", "degree c", "deg c", "centigrade", "celzija", "stopinj", "stopinj celzija"]),
            (UnitTemperature.fahrenheit, "°F", "Fahrenheit", ["f", "°f", "fahrenheit", "degf", "degrees fahrenheit", "degree fahrenheit", "degrees f", "degree f", "deg f", "fahrenheita", "stopinj fahrenheita"]),
            (UnitTemperature.kelvin, "K", "Kelvin", ["k", "kelvin", "kelvins"]),

            // Pressure
            (UnitPressure.newtonsPerMetersSquared, "Pa", "Pascals", ["pa", "pascal", "pascals"]),
            (UnitPressure.hectopascals, "hPa", "Hectopascals", ["hpa", "hectopascal", "hectopascals"]),
            (UnitPressure.kilopascals, "kPa", "Kilopascals", ["kpa", "kilopascal", "kilopascals"]),
            (UnitPressure.megapascals, "MPa", "Megapascals", ["mpa", "megapascal", "megapascals"]),
            (UnitPressure.bars, "bar", "Bars", ["bar", "bars"]),
            (UnitPressure.millibars, "mbar", "Millibars", ["mbar", "millibar", "millibars"]),
            (psi, "psi", "PSI", ["psi"]),
            (mmHg, "mmHg", "Millimeters of Mercury", ["mmhg"]),
            (inHg, "inHg", "Inches of Mercury", ["inhg"]),
            (atm, "atm", "Atmospheres", ["atm", "atmosphere", "atmospheres"]),
            (torr, "Torr", "Torr", ["torr"]),

            // Energy
            (UnitEnergy.joules, "J", "Joules", ["j", "joule", "joules"]),
            (UnitEnergy.kilojoules, "kJ", "Kilojoules", ["kj", "kilojoule", "kilojoules"]),
            (UnitEnergy.calories, "cal", "Calories", ["cal", "calorie", "calories"]),
            (UnitEnergy.kilocalories, "kcal", "Kilocalories", ["kcal", "kilocalorie", "kilocalories", "kalorij"]),
            (UnitEnergy.kilowattHours, "kWh", "Kilowatt-hours", ["kwh", "kilowatt hour", "kilowatt hours", "kilowatt-hour", "kilowatt-hours"]),
            (wattHour, "Wh", "Watt-hours", ["wh", "watt hour", "watt hours"]),
            (megajoule, "MJ", "Megajoules", ["mj", "megajoule", "megajoules"]),
            (btu, "BTU", "BTU", ["btu", "btus", "british thermal unit", "british thermal units"]),
            (electronVolt, "eV", "Electronvolts", ["ev", "electronvolt", "electronvolts", "electron volt", "electron volts"]),

            // Power
            (UnitPower.watts, "W", "Watts", ["w", "watt", "watts", "vat"]),
            (UnitPower.kilowatts, "kW", "Kilowatts", ["kw", "kilowatt", "kilowatts", "kilovat"]),
            (UnitPower.megawatts, "MW", "Megawatts", ["mw", "megawatt", "megawatts"]),
            (horsepower, "hp", "Horsepower", ["hp", "horsepower", "bhp"]),
            (metricHorsepower, "PS", "Metric Horsepower", ["ps", "ks", "konj", "konjev", "konjske moči", "konjskih moči", "metric horsepower", "cv"]),

            // Angle
            (UnitAngle.degrees, "°", "Degrees", ["°", "deg", "degree", "degrees", "stopinja", "stopinje"]),
            (UnitAngle.radians, "rad", "Radians", ["rad", "rads", "radian", "radians"]),
            (UnitAngle.gradians, "grad", "Gradians", ["grad", "gon", "gradian", "gradians"]),
            (UnitAngle.revolutions, "rev", "Turns", ["rev", "revs", "revolution", "revolutions", "turn", "turns"]),
            (UnitAngle.arcMinutes, "′", "Arcminutes", ["arcmin", "arcminute", "arcminutes"]),
            (UnitAngle.arcSeconds, "″", "Arcseconds", ["arcsec", "arcsecond", "arcseconds"]),

            // Frequency
            (UnitFrequency.hertz, "Hz", "Hertz", ["hz", "hertz"]),
            (UnitFrequency.kilohertz, "kHz", "Kilohertz", ["khz", "kilohertz"]),
            (UnitFrequency.megahertz, "MHz", "Megahertz", ["mhz", "megahertz"]),
            (UnitFrequency.gigahertz, "GHz", "Gigahertz", ["ghz", "gigahertz"]),
            (custom(UnitFrequency.self, "rpm", 1.0 / 60), "rpm", "RPM", ["rpm"]),

            // Fuel economy
            (UnitFuelEfficiency.litersPer100Kilometers, "L/100km", "Liters per 100 km", ["l/100km", "l/100 km", "l per 100km", "l per 100 km", "liters per 100km", "liters per 100 km", "litres per 100 km", "lp100km"]),
            (mpg, "mpg", "Miles per US Gallon", ["mpg", "miles per gallon", "us mpg"]),
            (mpgImperial, "mpg (imp)", "Miles per Imperial Gallon", ["imp mpg", "uk mpg", "mpg imp", "mpg uk", "miles per imperial gallon"]),
            (kmPerLiter, "km/L", "Kilometers per Liter", ["km/l", "kmpl", "km per liter", "km per litre", "kilometers per liter"]),
        ]
    }

    /// Data units: case matters (MB is megabytes, Mb is megabits).
    private static func dataEntries() -> [(Dimension, String, String, [String])] {
        typealias S = UnitInformationStorage
        return [
            (S.bytes, "B", "Bytes", ["B", "byte", "bytes"]),
            (S.bits, "bit", "Bits", ["b", "bit", "bits"]),
            (S.kilobytes, "kB", "Kilobytes", ["kB", "KB", "kb", "kilobyte", "kilobytes"]),
            (S.megabytes, "MB", "Megabytes", ["MB", "mb", "megabyte", "megabytes", "megs"]),
            (S.gigabytes, "GB", "Gigabytes", ["GB", "gb", "gigabyte", "gigabytes", "gigs"]),
            (S.terabytes, "TB", "Terabytes", ["TB", "tb", "terabyte", "terabytes"]),
            (S.petabytes, "PB", "Petabytes", ["PB", "pb", "petabyte", "petabytes"]),
            (S.kibibytes, "KiB", "Kibibytes", ["KiB", "kib", "kibibyte", "kibibytes"]),
            (S.mebibytes, "MiB", "Mebibytes", ["MiB", "mib", "mebibyte", "mebibytes"]),
            (S.gibibytes, "GiB", "Gibibytes", ["GiB", "gib", "gibibyte", "gibibytes"]),
            (S.tebibytes, "TiB", "Tebibytes", ["TiB", "tib", "tebibyte", "tebibytes"]),
            (S.kilobits, "kbit", "Kilobits", ["Kb", "kbit", "kbits", "kilobit", "kilobits"]),
            (S.megabits, "Mbit", "Megabits", ["Mb", "mbit", "mbits", "megabit", "megabits"]),
            (S.gigabits, "Gbit", "Gigabits", ["Gb", "gbit", "gbits", "gigabit", "gigabits"]),
            (S.terabits, "Tbit", "Terabits", ["Tb", "tbit", "terabit", "terabits"]),
            // Rates: lower-case "mbps" is megabits, as people write it; "mb/s" is megabytes, like "mb".
            (UnitDataRate.bitsPerSecond, "bit/s", "Bits per Second", ["bit/s", "bps", "bits per second"]),
            (rate(1e3), "kbit/s", "Kilobits per Second", ["kbps", "kbit/s", "Kb/s", "kilobits per second"]),
            (rate(1e6), "Mbit/s", "Megabits per Second", ["Mbps", "mbps", "Mb/s", "mbit/s", "megabits per second"]),
            (rate(1e9), "Gbit/s", "Gigabits per Second", ["Gbps", "gbps", "Gb/s", "gbit/s", "gigabits per second"]),
            (rate(8), "B/s", "Bytes per Second", ["B/s", "Bps", "bytes per second"]),
            (rate(8e3), "kB/s", "Kilobytes per Second", ["kB/s", "KB/s", "kb/s", "kBps", "kilobytes per second"]),
            (rate(8e6), "MB/s", "Megabytes per Second", ["MB/s", "MBps", "mb/s", "megabytes per second"]),
            (rate(8e9), "GB/s", "Gigabytes per Second", ["GB/s", "GBps", "gb/s", "gigabytes per second"]),
            (rate(8 * 1_048_576), "MiB/s", "Mebibytes per Second", ["MiB/s", "mib/s"]),
        ]
    }

    private static func rate(_ bitsPerSecond: Double) -> UnitDataRate { custom(UnitDataRate.self, "", bitsPerSecond) }

    private struct Tables {
        var exact: [String: UnitInfo] = [:] // case-sensitive (data units)
        var folded: [String: UnitInfo] = [:] // lower-cased
        var bySymbol: [String: UnitInfo] = [:]
        /// Folded aliases in table order, for completing a target typed in part.
        var aliases: [(alias: String, info: UnitInfo)] = []
    }

    nonisolated private static let tables: Tables = {
        var t = Tables()
        func fold(_ alias: String, _ info: UnitInfo) {
            let key = normalize(alias)
            guard t.folded[key] == nil else { return }
            t.folded[key] = info
            t.aliases.append((key, info))
        }
        for (unit, symbol, name, aliases) in entries() {
            let info = UnitInfo(unit: unit, symbol: symbol, name: name)
            t.bySymbol[symbol] = t.bySymbol[symbol] ?? info
            for a in aliases { fold(a, info) }
        }
        for (unit, symbol, name, aliases) in dataEntries() {
            let info = UnitInfo(unit: unit, symbol: symbol, name: name)
            t.bySymbol[symbol] = t.bySymbol[symbol] ?? info
            for a in aliases {
                if a.count <= 4, a != a.lowercased() { t.exact[a] = info } // MB, Mb, KiB
                else { fold(a, info) }
            }
        }
        return t
    }()

    /// Lower-cases and canonicalises unit spellings: "sq mile" → "mile2", "km²" → "km2", "cubic feet" → "feet3".
    static func normalize(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "²", with: "2").replacingOccurrences(of: "³", with: "3")
            .replacingOccurrences(of: "^2", with: "2").replacingOccurrences(of: "^3", with: "3")
        t = t.replacingOccurrences(of: "  ", with: " ")
        for (prefix, power) in [("square ", "2"), ("sq. ", "2"), ("sq ", "2"), ("cubic ", "3"), ("cu. ", "3"), ("cu ", "3")]
        where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)) + power
            break
        }
        for suffix in [" squared", " cubed"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count)) + (suffix == " squared" ? "2" : "3")
        }
        // Plural area/volume words ("miles2") fold to the singular alias where one exists.
        return t
    }

    static func unit(_ raw: String) -> UnitInfo? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let hit = tables.exact[s] { return hit }
        let key = normalize(s)
        if let hit = tables.folded[key] { return hit }
        // "meters2", "kilometres3": resolve the length word, then look up its area/volume form ("m2", "km3").
        if let last = key.last, last == "2" || last == "3" {
            let base = String(key.dropLast())
            if let length = tables.folded[base], length.unit is UnitLength {
                let symbol = length.symbol.lowercased()
                if let hit = tables.folded[symbol + String(last)] { return hit }
            }
        }
        return nil
    }

    /// A unit by its display symbol ("km", "°C", "MB/s").
    static func unit(symbol: String) -> UnitInfo? { tables.bySymbol[symbol] }

    /// The unit you most likely want when none is typed ("2 min =", "5 km", "30 c to").
    static let defaultTargets: [String: String] = [
        // Length
        "m": "ft", "km": "mi", "cm": "in", "mm": "in", "dm": "cm", "µm": "mm", "nm": "µm",
        "mi": "km", "yd": "m", "ft": "m", "in": "cm", "nmi": "km", "ly": "km", "au": "km",
        // Area
        "m²": "ft²", "km²": "mi²", "cm²": "in²", "mm²": "cm²", "mi²": "km²", "ft²": "m²", "in²": "cm²",
        "yd²": "m²", "ha": "ac", "ac": "ha", "a": "m²", "nmi²": "km²",
        // Volume
        "L": "gal", "mL": "fl oz", "cL": "fl oz", "dL": "cup", "m³": "L", "cm³": "mL", "mm³": "mL", "km³": "m³",
        "ft³": "L", "in³": "cm³", "yd³": "m³", "gal": "L", "imp gal": "L", "qt": "L", "pt": "mL", "cup": "mL",
        "fl oz": "mL", "tbsp": "mL", "tsp": "mL",
        // Mass
        "kg": "lb", "g": "oz", "mg": "g", "µg": "mg", "t": "ton", "ton": "t", "long ton": "t", "lb": "kg",
        "oz": "g", "st": "kg", "ct": "g",
        // Time
        "s": "min", "min": "s", "h": "min", "ms": "s", "µs": "ms", "ns": "µs", "d": "h", "wk": "d", "mo": "d", "yr": "d",
        // Speed
        "km/h": "mph", "m/s": "km/h", "mph": "km/h", "kn": "km/h", "ft/s": "m/s",
        // Temperature
        "°C": "°F", "°F": "°C", "K": "°C",
        // Pressure
        "Pa": "psi", "hPa": "inHg", "kPa": "psi", "MPa": "psi", "bar": "psi", "mbar": "inHg", "psi": "bar",
        "mmHg": "kPa", "inHg": "hPa", "atm": "bar", "Torr": "kPa",
        // Energy
        "J": "cal", "kJ": "kcal", "cal": "J", "kcal": "kJ", "kWh": "MJ", "Wh": "kJ", "MJ": "kWh", "BTU": "kJ", "eV": "J",
        // Power
        "W": "hp", "kW": "hp", "MW": "kW", "hp": "kW", "PS": "kW",
        // Angle
        "°": "rad", "rad": "°", "grad": "°", "rev": "°", "′": "°", "″": "′",
        // Frequency
        "Hz": "rpm", "kHz": "Hz", "MHz": "kHz", "GHz": "MHz", "rpm": "Hz",
        // Fuel economy
        "L/100km": "mpg", "mpg": "L/100km", "mpg (imp)": "L/100km", "km/L": "L/100km",
        // Data
        "B": "bit", "bit": "B", "kB": "KiB", "MB": "MiB", "GB": "GiB", "TB": "TiB", "PB": "TB",
        "KiB": "kB", "MiB": "MB", "GiB": "GB", "TiB": "TB", "kbit": "kB", "Mbit": "MB", "Gbit": "GB", "Tbit": "TB",
        // Data rate
        "bit/s": "B/s", "kbit/s": "kB/s", "Mbit/s": "MB/s", "Gbit/s": "MB/s", "B/s": "bit/s", "kB/s": "kbit/s",
        "MB/s": "Mbit/s", "GB/s": "Gbit/s", "MiB/s": "Mbit/s",
    ]

    /// A target typed in part, in the source's dimension: "sec" → seconds, "mil" → miles from km.
    static func completion(_ raw: String, like from: UnitInfo) -> UnitInfo? {
        let key = normalize(raw)
        guard key.count >= 2 else { return nil }
        return tables.aliases
            .filter { $0.alias.hasPrefix(key) && sameDimension($0.info.unit, from.unit) && $0.info.symbol != from.symbol }
            .min { $0.alias.count < $1.alias.count }?.info
    }

    // MARK: - Parsing

    private static let separatorWords: Set<String> = ["to", "in", "into", "as", "v", "na", "->", "→", "=", "=>"]
    private static let separatorSymbols = ["=>", "->", "→", "="]
    private static let questionPrefixes = [
        "convert ", "pretvori ", "what is ", "what's ", "whats ", "what are ", "how much is ", "how much are ",
        "koliko je ", "koliko so ",
    ]

    /// Every (quantity, target) split, left to right. Word separators split only between whole
    /// words, so "12 in to cm" also tries "12 in" | "cm" after "12" | "to cm" fails.
    static func splits(_ q: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for symbol in separatorSymbols {
            if let r = q.range(of: symbol) {
                out.append((String(q[..<r.lowerBound]), String(q[r.upperBound...])))
                break
            }
        }
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        for i in words.indices.dropFirst().dropLast() where separatorWords.contains(words[i].lowercased()) {
            out.append((words[..<i].joined(separator: " "), words[(i + 1)...].joined(separator: " ")))
        }
        return out
    }

    /// Parses and converts; nil when the input isn't a conversion.
    static func convert(_ input: String) -> Conversion? {
        var q = input.trimmingCharacters(in: .whitespaces)
        while q.hasSuffix("?") { q.removeLast() }
        guard q.count >= 2, q.count < 120,
              q.contains(where: \.isLetter) || q.contains("°") || q.contains("'") || q.contains("\"")
        else { return nil }
        var stripped = true
        while stripped {
            stripped = false
            for prefix in questionPrefixes where q.lowercased().hasPrefix(prefix) {
                q = String(q.dropFirst(prefix.count))
                stripped = true
            }
        }
        // "how many minutes in 2 days", "how many cm is 5 ft", "koliko minut je 2 uri", "koliko sekund ima dan"
        if let m = q.firstMatch(of: /(?i)^how (?:many|much)\s+(.+?)\s+(?:are there in|are in|is in|is there in|in|is|are|make|makes)\s+(.+)$/)
            ?? q.firstMatch(of: /(?i)^koliko\s+(.+?)\s+(?:je v|je|ima|imajo|gre v|v)\s+(.+)$/) {
            return pair(String(m.2), String(m.1))
        }
        for (left, right) in splits(q) {
            if let c = pair(left, right) { return c }
        }
        // No target: "2 min", "2 min =", "2 min to".
        for quantity in [q, droppingTrailingSeparator(q)].compactMap(\.self) {
            if let (value, from) = parseQuantity(quantity, requireNumber: true),
               let symbol = defaultTargets[from.symbol], let to = unit(symbol: symbol) {
                return make(value, from, to, implicit: true)
            }
        }
        return nil
    }

    private static func droppingTrailingSeparator(_ q: String) -> String? {
        let t = q.trimmingCharacters(in: .whitespaces)
        for symbol in separatorSymbols where t.hasSuffix(symbol) { return String(t.dropLast(symbol.count)) }
        let words = t.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, let last = words.last, separatorWords.contains(last.lowercased()) else { return nil }
        return words.dropLast().joined(separator: " ")
    }

    private static func pair(_ quantity: String, _ target: String) -> Conversion? {
        let typed = target.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, let (value, from) = parseQuantity(quantity) else { return nil }
        let exact = unit(typed).flatMap { sameDimension($0.unit, from.unit) ? $0 : nil }
        guard let to = exact ?? completion(typed, like: from) else { return nil }
        return make(value, from, to, implicit: false)
    }

    private static func make(_ value: Double, _ from: UnitInfo, _ to: UnitInfo, implicit: Bool) -> Conversion? {
        guard sameDimension(from.unit, to.unit), from.symbol != to.symbol || from.name != to.name else { return nil }
        let result = Measurement(value: value, unit: from.unit).converted(to: to.unit).value
        guard result.isFinite else { return nil }
        return Conversion(value: value, result: result, from: from.symbol, to: to.symbol, fromName: from.name,
                          toName: to.name, implicitTarget: implicit)
    }

    /// "734h", "1 sq mile", "2*3 km", "1e3 m", "1.5k km", "half an hour", "1h 30min", "km" (= 1 km,
    /// unless `requireNumber`).
    static func parseQuantity(_ raw: String, requireNumber: Bool = false) -> (Double, UnitInfo)? {
        let s = digitsForWords(raw.trimmingCharacters(in: .whitespaces))
        if let compound = parseCompound(s) { return compound }
        let chars = Array(s)
        for i in 0..<chars.count {
            // A unit starts at the beginning, after a space, or right after a digit / ')' / '.'.
            if i > 0 {
                let prev = chars[i - 1]
                guard prev == " " || prev.isNumber || prev == ")" || prev == "." || prev == "," else { continue }
            }
            let suffix = String(chars[i...])
            guard let u = unit(suffix) else { continue }
            let prefix = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            if prefix.isEmpty {
                if requireNumber { continue }
                return (1, u)
            }
            if let v = number(prefix) { return (v, u) }
        }
        return nil
    }

    /// An expression ("2*3", "1/2", "1,5"), scientific notation ("1e3") or a k / M multiple ("1.5k").
    static func number(_ text: String) -> Double? {
        if let v = try? Calculator.evaluate(text) { return NSDecimalNumber(decimal: v).doubleValue }
        let t = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v.isFinite { return v }
        for (suffix, factor) in [("k", 1e3), ("K", 1e3), ("M", 1e6)] where t.hasSuffix(suffix) {
            if let v = Double(t.dropLast()), v.isFinite { return v * factor }
        }
        return nil
    }

    /// Several parts of one dimension, summed into the first part's unit: "1h 30min", "5 ft 11 in",
    /// "5'11\"", "2 hours and 30 minutes".
    static func parseCompound(_ raw: String) -> (Double, UnitInfo)? {
        let s = raw.replacingOccurrences(of: " and ", with: " ")
        let parts = s.matches(of: /(\d+(?:[.,]\d+)?)\s*([^\d\s][^\d]*?)\s*(?=\d|$)/)
        guard parts.count >= 2,
              s.replacing(/(\d+(?:[.,]\d+)?)\s*([^\d\s][^\d]*?)\s*(?=\d|$)/, with: "").allSatisfy(\.isWhitespace)
        else { return nil }
        var total = 0.0
        var first: UnitInfo?
        for part in parts {
            guard let v = Double(part.1.replacingOccurrences(of: ",", with: ".")),
                  let u = unit(String(part.2).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: [","]))
            else { return nil }
            if let f = first {
                guard sameDimension(f.unit, u.unit) else { return nil }
            } else {
                first = u
            }
            total += Measurement(value: v, unit: u.unit).converted(to: first!.unit).value
        }
        return first.map { (total, $0) }
    }

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "hundred": "100", "thousand": "1000",
        "dozen": "12", "half": "0.5", "quarter": "0.25",
        "en": "1", "ena": "1", "eno": "1", "enega": "1", "dva": "2", "dve": "2", "tri": "3", "štiri": "4",
        "pet": "5", "šest": "6", "sedem": "7", "osem": "8", "devet": "9", "deset": "10", "pol": "0.5", "četrt": "0.25",
    ]

    /// "a day", "an hour", "half an hour", "two weeks", "pol ure" → "1 day", "0.5 hour", …
    static func digitsForWords(_ s: String) -> String {
        let words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2 else { return s }
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i].lowercased()
            let hasNext = i + 1 < words.count
            if hasNext, let n = numberWords[w] {
                out.append(n)
                i += 1
                // "half an hour", "a quarter of an hour"
                while i < words.count - 1, ["a", "an", "of"].contains(words[i].lowercased()) { i += 1 }
                continue
            }
            if i == 0, hasNext, w == "a" || w == "an" {
                if numberWords[words[1].lowercased()] == nil { out.append("1") }
                i += 1
                continue
            }
            out.append(words[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: - Formatting

    static func format(_ x: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        let magnitude = abs(x)
        if magnitude != 0 && (magnitude >= 1e15 || magnitude < 1e-6) {
            f.numberStyle = .scientific
            f.maximumSignificantDigits = 6
        } else {
            f.numberStyle = .decimal
            f.usesGroupingSeparator = false
            f.usesSignificantDigits = true
            f.maximumSignificantDigits = 10
        }
        return f.string(from: NSNumber(value: x)) ?? "\(x)"
    }
}
