// Owns the unit table: names, symbols, the units Raycast converts single quantities to, and
// conversion through NSMeasurement.
#import "calcunits.h"

/// One unit: its factor to its NSDimension subclass's base (metres, kilograms,
/// litres, square metres, metres per second, kelvin, bytes, seconds, joules, watts, pascals,
/// degrees, hertz); how it is written after a number, singular then plural; what it is
/// converted to on its own; and the names it is typed as, separated by "|", where a
/// leading "=" makes the case count (Mb is megabits, MB megabytes).
typedef struct {
    const char *identifier, *symbol, *singular, *plural;
    double coefficient, constant;
    const char *counterpart, *aliases;
} Spec;

// Foundation's own units round their factors (a mile is 1609.34 m there), so every unit
// is made with the exact factor Raycast uses.
static const Spec kSpecs[] = {
    {"millimeters", "mm", "mm", NULL, 0.001, 0, NULL, "mm|millimeter|millimeters|millimetre|millimetres"},
    {"centimeters", "cm", "cm", NULL, 0.01, 0, "inches", "cm|centimeter|centimeters|centimetre|centimetres"},
    {"meters", "m", "m", NULL, 1, 0, "feet", "m|meter|meters|metre|metres"},
    {"kilometers", "km", "km", NULL, 1000, 0, "miles", "km|kms|kilometer|kilometers|kilometre|kilometres"},
    {"micrometers", "μm", "μm", NULL, 1e-6, 0, NULL, "μm|µm|um|micrometer|micrometers|micrometre|micrometres|micron|microns"},
    {"nanometers", "nm", "nm", NULL, 1e-9, 0, NULL, "nm|nanometer|nanometers|nanometre|nanometres"},
    {"inches", "in", "inch", "inches", 0.0254, 0, "centimeters", "in|inch|inches|\""},
    {"feet", "ft", "foot", "feet", 0.3048, 0, "meters", "ft|foot|feet|'"},
    {"yards", "yd", "yd", NULL, 0.9144, 0, "meters", "yd|yds|yard|yards"},
    {"miles", "mi", "mi", NULL, 1609.344, 0, "kilometers", "mi|mile|miles"},
    {"nauticalMiles", "nmi", "nmi", NULL, 1852, 0, NULL, "nautical mile|nautical miles"},
    {"lightYears", "ly", "ly", NULL, 9460730472580800, 0, NULL, "ly|light year|light years|lightyear|lightyears"},

    {"milligrams", "mg", "mg", NULL, 1e-6, 0, NULL, "mg|milligram|milligrams"},
    {"grams", "g", "g", NULL, 0.001, 0, "ounces", "g|gram|grams|gramme|grammes"},
    {"kilograms", "kg", "kg", NULL, 1, 0, "pounds", "kg|kgs|kilo|kilos|kilogram|kilograms"},
    {"metricTons", "t", "t", NULL, 1000, 0, "shortTons", "t|tonne|tonnes|metric ton|metric tons"},
    {"pounds", "lb", "lb", NULL, 0.45359237, 0, "kilograms", "lb|lbs|pound|pounds"},
    {"ounces", "oz", "oz", NULL, 0.028349523125, 0, "grams", "oz|ounce|ounces"},
    {"stones", "st", "st", NULL, 6.35029318, 0, NULL, "st|stone|stones"},
    {"shortTons", "ton", "ton", NULL, 907.18474, 0, NULL, "ton|tons|short ton|short tons"},

    {"milliliters", "mL", "mL", NULL, 0.001, 0, NULL, "ml|milliliter|milliliters|millilitre|millilitres"},
    {"centiliters", "cL", "cL", NULL, 0.01, 0, NULL, "cl|centiliter|centiliters|centilitre|centilitres"},
    {"deciliters", "dL", "dL", NULL, 0.1, 0, NULL, "dl|deciliter|deciliters|decilitre|decilitres"},
    {"liters", "L", "L", NULL, 1, 0, "gallons", "l|liter|liters|litre|litres"},
    {"cubicMeters", "m³", "m³", NULL, 1000, 0, NULL, "m3|m³|cubic meter|cubic meters|cubic metre|cubic metres"},
    {"cubicCentimeters", "cm³", "cm³", NULL, 0.001, 0, NULL, "cm3|cm³|cc|cubic centimeter|cubic centimeters"},
    {"cubicFeet", "ft³", "ft³", NULL, 28.316846592, 0, NULL, "ft3|ft³|cubic foot|cubic feet"},
    {"cubicInches", "in³", "in³", NULL, 0.016387064, 0, NULL, "in3|in³|cubic inch|cubic inches"},
    {"gallons", "gal", "gal", NULL, 3.785411784, 0, "liters", "gal|gallon|gallons"},
    {"quarts", "qt", "qt", NULL, 0.946352946, 0, NULL, "qt|quart|quarts"},
    {"pints", "pt", "pt", NULL, 0.473176473, 0, NULL, "pt|pint|pints"},
    {"cups", "cup", "metric cup", NULL, 0.25, 0, NULL, "cup|cups"},
    {"fluidOunces", "fl oz", "fl oz", NULL, 0.0295735295625, 0, NULL, "fl oz|floz|fluid ounce|fluid ounces"},
    {"tablespoons", "tbsp", "tbsp", NULL, 0.015, 0, NULL, "tbsp|tablespoon|tablespoons"},
    {"teaspoons", "tsp", "tsp", NULL, 0.005, 0, NULL, "tsp|teaspoon|teaspoons"},

    {"squareMillimeters", "mm²", "mm²", NULL, 1e-6, 0, NULL, "mm2|mm²|sq mm|square millimeter|square millimeters"},
    {"squareCentimeters", "cm²", "cm²", NULL, 1e-4, 0, NULL, "cm2|cm²|sq cm|square centimeter|square centimeters"},
    {"squareMeters", "m²", "m²", NULL, 1, 0, NULL, "m2|m²|sqm|sq m|square meter|square meters|square metre|square metres"},
    {"squareKilometers", "km²", "km²", NULL, 1e6, 0, NULL, "km2|km²|sq km|square kilometer|square kilometers|square kilometre|square kilometres"},
    {"hectares", "ha", "ha", NULL, 1e4, 0, NULL, "ha|hectare|hectares"},
    {"acres", "ac", "ac", NULL, 4046.8564224, 0, NULL, "ac|acre|acres"},
    {"squareFeet", "ft²", "ft²", NULL, 0.09290304, 0, NULL, "ft2|ft²|sqft|sq ft|square foot|square feet"},
    {"squareInches", "in²", "in²", NULL, 0.00064516, 0, NULL, "in2|in²|sq in|square inch|square inches"},
    {"squareYards", "yd²", "yd²", NULL, 0.83612736, 0, NULL, "yd2|yd²|sq yd|square yard|square yards"},
    {"squareMiles", "mi²", "mi²", NULL, 2589988.110336, 0, NULL, "mi2|mi²|sq mi|square mile|square miles"},

    {"metersPerSecond", "m/s", "m/s", NULL, 1, 0, NULL, "m/s|mps|meters per second|metres per second"},
    {"kilometersPerHour", "km/h", "km/h", NULL, 1 / 3.6, 0, NULL, "km/h|kmh|kph|kmph|kilometers per hour|kilometres per hour"},
    {"milesPerHour", "mph", "mph", NULL, 0.44704, 0, NULL, "mph|mi/h|miles per hour"},
    {"knots", "kn", "kn", NULL, 1852.0 / 3600, 0, NULL, "kn|knot|knots"},
    {"feetPerSecond", "ft/s", "ft/s", NULL, 0.3048, 0, NULL, "ft/s|fps|feet per second"},

    // Written as typed: "100 c in f" is "212 f", "100 °C to °F" is "212 °F".
    {"celsius", "°C", "°C", NULL, 1, 273.15, "fahrenheit", "°c|℃|celsius|degc|degrees celsius"},
    {"celsius", "c", "c", NULL, 1, 273.15, "fahrenheit", "c"},
    {"fahrenheit", "°F", "°F", NULL, 5.0 / 9, 459.67 * 5 / 9, "celsius", "°f|℉|fahrenheit|degf|degrees fahrenheit"},
    {"fahrenheit", "f", "f", NULL, 5.0 / 9, 459.67 * 5 / 9, "celsius", "f"},
    {"kelvin", "K", "K", NULL, 1, 0, NULL, "k|kelvin|kelvins"},

    {"bits", "bit", "bit", NULL, 0.125, 0, NULL, "bit|bits"},
    {"kilobits", "kbit", "kbit", NULL, 125, 0, NULL, "kbit|kilobit|kilobits|=Kb"},
    {"megabits", "Mbit", "Mbit", NULL, 125e3, 0, NULL, "mbit|megabit|megabits|=Mb"},
    {"gigabits", "Gbit", "Gbit", NULL, 125e6, 0, NULL, "gbit|gigabit|gigabits|=Gb"},
    {"terabits", "Tbit", "Tbit", NULL, 125e9, 0, NULL, "tbit|terabit|terabits|=Tb"},
    {"bytes", "B", "B", NULL, 1, 0, NULL, "byte|bytes|=B"},
    {"kilobytes", "kB", "kB", NULL, 1e3, 0, NULL, "kb|kilobyte|kilobytes"},
    {"megabytes", "MB", "MB", NULL, 1e6, 0, NULL, "mb|megabyte|megabytes"},
    {"gigabytes", "GB", "GB", NULL, 1e9, 0, NULL, "gb|gigabyte|gigabytes"},
    {"terabytes", "TB", "TB", NULL, 1e12, 0, NULL, "tb|terabyte|terabytes"},
    {"petabytes", "PB", "PB", NULL, 1e15, 0, NULL, "pb|petabyte|petabytes"},
    {"kibibytes", "KiB", "KiB", NULL, 1024, 0, NULL, "kib|kibibyte|kibibytes"},
    {"mebibytes", "MiB", "MiB", NULL, 1048576, 0, NULL, "mib|mebibyte|mebibytes"},
    {"gibibytes", "GiB", "GiB", NULL, 1073741824, 0, NULL, "gib|gibibyte|gibibytes"},
    {"tebibytes", "TiB", "TiB", NULL, 1099511627776, 0, NULL, "tib|tebibyte|tebibytes"},

    {"nanoseconds", "ns", "ns", NULL, 1e-9, 0, "milliseconds", "ns|nanosecond|nanoseconds"},
    {"microseconds", "μs", "μs", NULL, 1e-6, 0, NULL, "μs|µs|us|microsecond|microseconds"},
    {"milliseconds", "ms", "ms", NULL, 1e-3, 0, "seconds", "ms|millisecond|milliseconds"},
    {"seconds", "s", "s", NULL, 1, 0, NULL, "s|sec|secs|second|seconds"},
    {"minutes", "min", "min", NULL, 60, 0, NULL, "min|mins|minute|minutes"},
    {"hours", "hr", "hour", "hours", 3600, 0, "minutes", "h|hr|hrs|hour|hours"},
    {"days", "day", "day", "days", 86400, 0, "weeks", "d|day|days"},
    {"weeks", "week", "week", "weeks", 604800, 0, "days", "wk|wks|week|weeks"},
    {"months", "month", "month", "months", 2629746, 0, NULL, "mo|month|months"},
    {"years", "year", "year", "years", 31556952, 0, NULL, "y|yr|yrs|year|years"},

    {"joules", "J", "J", NULL, 1, 0, "calories", "j|joule|joules"},
    {"kilojoules", "kJ", "kJ", NULL, 1e3, 0, "kilocalories", "kj|kilojoule|kilojoules"},
    {"calories", "cal", "cal", NULL, 4.184, 0, "joules", "cal|calorie|calories"},
    {"kilocalories", "kCal", "kCal", NULL, 4184, 0, "kilojoules", "kcal|kilocalorie|kilocalories"},
    {"wattHours", "Wh", "Wh", NULL, 3600, 0, NULL, "wh|watt hour|watt hours"},
    {"kilowattHours", "kWh", "kWh", NULL, 3.6e6, 0, NULL, "kwh|kilowatt hour|kilowatt hours"},
    {"electronvolts", "eV", "eV", NULL, 1.602176634e-19, 0, NULL, "ev|electronvolt|electronvolts"},
    {"britishThermalUnits", "BTU", "BTU", NULL, 1055.05585262, 0, NULL, "btu|btus"},

    {"watts", "W", "W", NULL, 1, 0, NULL, "w|watt|watts"},
    {"kilowatts", "kW", "kW", NULL, 1e3, 0, NULL, "kw|kilowatt|kilowatts"},
    {"horsepower", "hp", "hp", NULL, 745.6998715822702, 0, NULL, "hp|horsepower"},

    {"pascals", "Pa", "Pa", NULL, 1, 0, NULL, "pa|pascal|pascals"},
    {"hectopascals", "hPa", "hPa", NULL, 100, 0, NULL, "hpa|hectopascal|hectopascals"},
    {"kilopascals", "kPa", "kPa", NULL, 1e3, 0, NULL, "kpa|kilopascal|kilopascals"},
    {"bars", "bar", "bar", NULL, 1e5, 0, "pascals", "bar|bars"},
    {"millibars", "mbar", "mbar", NULL, 100, 0, NULL, "mbar|millibar|millibars"},
    {"poundsForcePerSquareInch", "psi", "psi", NULL, 6894.757293168362, 0, NULL, "psi"},
    {"atmospheres", "atm", "atm", NULL, 101325, 0, NULL, "atm|atmosphere|atmospheres"},
    {"millimetersOfMercury", "mmHg", "mmHg", NULL, 133.322387415, 0, NULL, "mmhg"},

    {"degrees", "°", "°", NULL, 1, 0, "radians", "°|deg|degree|degrees"},
    {"radians", "rad", "rad", NULL, 180 / M_PI, 0, "degrees", "rad|rads|radian|radians"},
    {"gradians", "grad", "grad", NULL, 0.9, 0, NULL, "grad|grads|gradian|gradians"},
    {"arcMinutes", "′", "′", NULL, 1.0 / 60, 0, NULL, "arcmin|arcminute|arcminutes|′"},
    {"arcSeconds", "″", "″", NULL, 1.0 / 3600, 0, NULL, "arcsec|arcsecond|arcseconds|″"},

    {"hertz", "Hz", "Hz", NULL, 1, 0, NULL, "hz|hertz"},
    {"kilohertz", "kHz", "kHz", NULL, 1e3, 0, NULL, "khz|kilohertz"},
    {"megahertz", "MHz", "MHz", NULL, 1e6, 0, NULL, "mhz|megahertz"},
    {"gigahertz", "GHz", "GHz", NULL, 1e9, 0, NULL, "ghz|gigahertz"},
};

/// The dimension class of each run of the table, by the identifier that starts it.
static Class DimensionStartingAt(const char *identifier) {
    NSDictionary<NSString *, Class> *starts = @{
        @"millimeters" : NSUnitLength.class, @"milligrams" : NSUnitMass.class, @"milliliters" : NSUnitVolume.class,
        @"squareMillimeters" : NSUnitArea.class, @"metersPerSecond" : NSUnitSpeed.class, @"celsius" : NSUnitTemperature.class,
        @"bits" : NSUnitInformationStorage.class, @"nanoseconds" : NSUnitDuration.class, @"joules" : NSUnitEnergy.class,
        @"watts" : NSUnitPower.class, @"pascals" : NSUnitPressure.class, @"degrees" : NSUnitAngle.class,
        @"hertz" : NSUnitFrequency.class,
    };
    return starts[@(identifier)];
}

@implementation DKCalcUnit {
    NSString *_singular, *_plural, *_counterpartIdentifier;
}

- (DKCalcUnit *)counterpart {
    return _counterpartIdentifier ? DKUnitWithIdentifier(_counterpartIdentifier) : nil;
}

- (BOOL)isDuration { return [_dimension isKindOfClass:NSUnitDuration.class]; }

- (NSString *)write:(NSString *)number value:(double)value {
    NSString *name = fabs(value) == 1 ? _singular : _plural;
    // Degrees, minutes and seconds of arc sit against the number; "°F" and the rest do not.
    BOOL attached = [name isEqualToString:@"°"] || [name isEqualToString:@"′"] || [name isEqualToString:@"″"];
    return [NSString stringWithFormat:attached ? @"%@%@" : @"%@ %@", number, name];
}

/// "squareFeet" as "Square Feet".
static NSString *LabelFor(NSString *identifier) {
    NSMutableString *label = [NSMutableString new];
    for (NSUInteger i = 0; i < identifier.length; i++) {
        unichar c = [identifier characterAtIndex:i];
        if (i == 0) c = (unichar)toupper(c);
        else if (isupper(c)) [label appendString:@" "];
        [label appendFormat:@"%C", c];
    }
    return label;
}

static NSArray<DKCalcUnit *> *units;
/// Typed names in lowercase, and those whose case counts as typed.
static NSDictionary<NSString *, DKCalcUnit *> *byName, *byExactName;
static NSUInteger longestName;

static void MakeUnits(void) {
    if (units) return;
    NSMutableArray *all = [NSMutableArray new];
    NSMutableDictionary *names = [NSMutableDictionary new], *exactNames = [NSMutableDictionary new];
    Class dimension = nil;
    for (size_t i = 0; i < sizeof kSpecs / sizeof *kSpecs; i++) {
        Spec spec = kSpecs[i];
        dimension = DimensionStartingAt(spec.identifier) ?: dimension;
        DKCalcUnit *unit = [DKCalcUnit new];
        unit->_identifier = @(spec.identifier);
        unit->_symbol = @(spec.symbol);
        unit->_label = LabelFor(unit->_identifier);
        unit->_singular = @(spec.singular);
        unit->_plural = spec.plural ? @(spec.plural) : unit->_singular;
        unit->_counterpartIdentifier = spec.counterpart ? @(spec.counterpart) : nil;
        NSUnitConverter *converter = [[NSUnitConverterLinear alloc] initWithCoefficient:spec.coefficient constant:spec.constant];
        unit->_dimension = [[dimension alloc] initWithSymbol:unit->_symbol converter:converter];
        [all addObject:unit];
        for (NSString *alias in [@(spec.aliases) componentsSeparatedByString:@"|"]) {
            if ([alias hasPrefix:@"="]) exactNames[[alias substringFromIndex:1]] = unit;
            else names[alias] = names[alias] ?: unit;
            longestName = MAX(longestName, alias.length);
        }
    }
    units = all;
    byName = names;
    byExactName = exactNames;
}

DKCalcUnit *DKUnitWithIdentifier(NSString *identifier) {
    MakeUnits();
    for (DKCalcUnit *unit in units)
        if ([unit.identifier isEqualToString:identifier]) return unit;
    return nil;
}

static BOOL IsWordCharacter(unichar c) { return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c]; }

DKCalcUnit *DKUnitAt(NSString *text, NSUInteger index, NSUInteger *length) {
    MakeUnits();
    for (NSUInteger count = MIN(longestName, text.length - index); count > 0; count--) {
        NSString *candidate = [text substringWithRange:NSMakeRange(index, count)];
        DKCalcUnit *unit = byExactName[candidate] ?: byName[candidate.lowercaseString];
        if (!unit) continue;
        // "m" is no unit in "mph", but "'" ends a unit wherever it is.
        unichar last = [candidate characterAtIndex:count - 1];
        if (IsWordCharacter(last) && index + count < text.length && IsWordCharacter([text characterAtIndex:index + count])) continue;
        *length = count;
        return unit;
    }
    return nil;
}

BOOL DKUnitsConvertible(DKCalcUnit *from, DKCalcUnit *to) { return from.dimension.class == to.dimension.class; }

double DKConvertUnit(double value, DKCalcUnit *from, DKCalcUnit *to) {
    if (from == to) return value;
    NSMeasurement *measurement = [[NSMeasurement alloc] initWithDoubleValue:value unit:from.dimension];
    double converted = [measurement measurementByConvertingToUnit:to.dimension].doubleValue;
    // Through the base unit and back, 100 °C comes out as 211.99999999999997 °F; fifteen
    // significant digits are all a double holds for certain.
    char digits[32];
    snprintf(digits, sizeof digits, "%.15g", converted);
    return strtod(digits, NULL);
}

@end
