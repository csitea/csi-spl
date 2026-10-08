// spec 089 T009 (AC-08) tested the Calendar's first phone layout here: the
// year strip as a sheet behind a header button, the main view's Day view
// and its Week list. spec 106 T011 retired that layout; a phone (<= 820 px)
// now gets CalendarPhone for everyone, tested by:
//   calendar-phone-shell.test.mjs  the shell, H1..H8, FR-011 (1440 unchanged),
//                                  and a fresh browser at 390 gets it (T011)
//   calendar-phone-month.test.mjs  Month (T005)
//   calendar-phone-week.test.mjs   Week (T006)
//   calendar-phone-day.test.mjs    Day, hold-drag (T007)
//   calendar-phone-sheet.test.mjs  the add / edit sheet (T008)
//   calendar-phone-peek.test.mjs   peek, delete, Undo (T009)
//   calendar-phone-jump.test.mjs   month picker, search (T010)
// This file stays as the pointer (the runner discovers every *.test.mjs,
// so it checks nothing and passes).
console.log('calendar-phone: retired by spec 106 T011, see the calendar-phone-*.test.mjs files')
