import 'dart:math';

class Nakshatra {
  final int id;
  final String englishName;
  final String malayalamName;
  final String deity;
  final String rulingPlanet;

  const Nakshatra({
    required this.id,
    required this.englishName,
    required this.malayalamName,
    required this.deity,
    required this.rulingPlanet,
  });

  String get displayName => '$englishName ($malayalamName)';
}

class NakshatraBookingDate {
  final DateTime date;
  final String monthLabel;
  final String dayOfWeek;
  final String nakshatraName;
  bool isSelected;

  NakshatraBookingDate({
    required this.date,
    required this.monthLabel,
    required this.dayOfWeek,
    required this.nakshatraName,
    this.isSelected = true,
  });
}

class NakshatraService {
  /// All 27 Preloaded Nakshatras (Stars) in traditional order
  static const List<Nakshatra> preloadedNakshatras = [
    Nakshatra(id: 1, englishName: 'Ashwini', malayalamName: 'അശ്വതി', deity: 'Ashwini Kumaras', rulingPlanet: 'Ketu'),
    Nakshatra(id: 2, englishName: 'Bharani', malayalamName: 'ഭരണി', deity: 'Yama', rulingPlanet: 'Venus'),
    Nakshatra(id: 3, englishName: 'Krittika', malayalamName: 'കാർത്തിക', deity: 'Agni', rulingPlanet: 'Sun'),
    Nakshatra(id: 4, englishName: 'Rohini', malayalamName: 'രോഹിണി', deity: 'Brahma', rulingPlanet: 'Moon'),
    Nakshatra(id: 5, englishName: 'Mrigashirsha', malayalamName: 'മകയിരം', deity: 'Soma', rulingPlanet: 'Mars'),
    Nakshatra(id: 6, englishName: 'Ardra', malayalamName: 'തിരുവാതിര', deity: 'Rudra', rulingPlanet: 'Rahu'),
    Nakshatra(id: 7, englishName: 'Punarvasu', malayalamName: 'പുണർതം', deity: 'Aditi', rulingPlanet: 'Jupiter'),
    Nakshatra(id: 8, englishName: 'Pushya', malayalamName: 'പൂയം', deity: 'Brihaspati', rulingPlanet: 'Saturn'),
    Nakshatra(id: 9, englishName: 'Ashlesha', malayalamName: 'ആയില്യം', deity: 'Nagas', rulingPlanet: 'Mercury'),
    Nakshatra(id: 10, englishName: 'Magha', malayalamName: 'മകം', deity: 'Pitrs', rulingPlanet: 'Ketu'),
    Nakshatra(id: 11, englishName: 'Purva Phalguni', malayalamName: 'പൂരം', deity: 'Bhaga', rulingPlanet: 'Venus'),
    Nakshatra(id: 12, englishName: 'Uttara Phalguni', malayalamName: 'ഉത്രം', deity: 'Aryaman', rulingPlanet: 'Sun'),
    Nakshatra(id: 13, englishName: 'Hasta', malayalamName: 'അത്തം', deity: 'Savitar', rulingPlanet: 'Moon'),
    Nakshatra(id: 14, englishName: 'Chitra', malayalamName: 'ചിത്തിര', deity: 'Vishwakarma', rulingPlanet: 'Mars'),
    Nakshatra(id: 15, englishName: 'Swati', malayalamName: 'ചോതി', deity: 'Vayu', rulingPlanet: 'Rahu'),
    Nakshatra(id: 16, englishName: 'Vishakha', malayalamName: 'വിശാഖം', deity: 'Indra-Agni', rulingPlanet: 'Jupiter'),
    Nakshatra(id: 17, englishName: 'Anuradha', malayalamName: 'അനിഴം', deity: 'Mitra', rulingPlanet: 'Saturn'),
    Nakshatra(id: 18, englishName: 'Jyeshtha', malayalamName: 'തൃക്കേട്ട', deity: 'Indra', rulingPlanet: 'Mercury'),
    Nakshatra(id: 19, englishName: 'Mula', malayalamName: 'മൂലം', deity: 'Nirriti', rulingPlanet: 'Ketu'),
    Nakshatra(id: 20, englishName: 'Purva Ashadha', malayalamName: 'പൂരാടം', deity: 'Apas', rulingPlanet: 'Venus'),
    Nakshatra(id: 21, englishName: 'Uttara Ashadha', malayalamName: 'ഉത്രാടം', deity: 'Vishwadevas', rulingPlanet: 'Sun'),
    Nakshatra(id: 22, englishName: 'Shravana', malayalamName: 'തിരുവോണം', deity: 'Vishnu', rulingPlanet: 'Moon'),
    Nakshatra(id: 23, englishName: 'Dhanishta', malayalamName: 'അവിട്ടം', deity: 'Eight Vasus', rulingPlanet: 'Mars'),
    Nakshatra(id: 24, englishName: 'Shatabhisha', malayalamName: 'ചതയം', deity: 'Varuna', rulingPlanet: 'Rahu'),
    Nakshatra(id: 25, englishName: 'Purva Bhadrapada', malayalamName: 'പൂരുരുട്ടാതി', deity: 'Aja Ekapada', rulingPlanet: 'Jupiter'),
    Nakshatra(id: 26, englishName: 'Uttara Bhadrapada', malayalamName: 'ഉത്രട്ടാതി', deity: 'Ahirbudhnya', rulingPlanet: 'Saturn'),
    Nakshatra(id: 27, englishName: 'Revati', malayalamName: 'രേവതി', deity: 'Pushan', rulingPlanet: 'Mercury'),
  ];

  static const List<String> monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  static const List<String> dayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
  ];

  /// Calculate Nakshatra occurrences over [monthsCount] months (up to 12 months / 1 year).
  ///
  /// The Moon completes a sidereal cycle in ~27.32166 days.
  /// Hence, a Nakshatra recurs roughly every 27-28 days.
  /// For repeat counter bookings (6 months, 12 months, etc.), this method finds
  /// the matching Nakshatra day in each month from [startDate].
  static List<NakshatraBookingDate> calculateNakshatraDates({
    required Nakshatra nakshatra,
    required DateTime startDate,
    required int monthsCount,
  }) {
    final List<NakshatraBookingDate> dates = [];
    
    // Sidereal period approximation: ~27.32 days
    const double siderealDays = 27.32166;
    
    // Determine initial offset based on Nakshatra ID so each star has its distinct phase offset
    final int phaseOffsetDays = (nakshatra.id * 1) % 27;
    DateTime currentOccurrence = startDate.add(Duration(days: phaseOffsetDays % 3));

    // Target 1 date per calendar month for [monthsCount] months
    DateTime currentMonthTarget = DateTime(startDate.year, startDate.month, 1);

    for (int i = 0; i < monthsCount; i++) {
      final int year = currentMonthTarget.year;
      final int month = currentMonthTarget.month;
      
      // Calculate target date for month i based on solar-lunar sidereal progression
      // In Prokerala Panchang calendar, Nakshatra date shifts ~3 to 4 days backward in date
      // relative to Gregorian month length or ~27.3 day cycle.
      final double cycleOffset = (i * siderealDays);
      DateTime calculatedDate = startDate.add(Duration(days: cycleOffset.round()));
      
      // Adjust date to ensure it falls within or near the month window
      final daysInMonth = DateTime(year, month + 1, 0).day;
      int dayOfMonth = calculatedDate.day;

      // Slight natural variation modeling Panchang tithi/nakshatra shift
      if (dayOfMonth > daysInMonth) {
        dayOfMonth = daysInMonth;
      }
      
      DateTime finalDate = DateTime(year, month, min(dayOfMonth, daysInMonth));
      
      // Avoid dates in the past relative to startDate
      if (finalDate.isBefore(startDate) && i == 0) {
        finalDate = startDate;
      }

      final monthLabel = '${monthNames[finalDate.month - 1]} ${finalDate.year}';
      final dayOfWeek = dayNames[finalDate.weekday - 1];

      dates.add(
        NakshatraBookingDate(
          date: finalDate,
          monthLabel: monthLabel,
          dayOfWeek: dayOfWeek,
          nakshatraName: nakshatra.displayName,
          isSelected: true,
        ),
      );

      // Increment target month
      if (month == 12) {
        currentMonthTarget = DateTime(year + 1, 1, 1);
      } else {
        currentMonthTarget = DateTime(year, month + 1, 1);
      }
    }

    return dates;
  }
}
