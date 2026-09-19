package mail

import (
	"strconv"
	"time"
)

// Duration words a link lifetime ("24 hours", "90 minutes") in locale, with
// that language's CLDR cardinal plural rule, in the counting (nominative)
// form. A whole number of hours is said in hours, anything else in minutes
// (rounded), as the English wording always did. The templates place it where
// the counting form reads naturally ("…: 24 tuntia").
func Duration(locale string, d time.Duration) string {
	if d < time.Minute {
		d = time.Minute
	}
	u, n := unitsMinute, int(d.Round(time.Minute)/time.Minute)
	if d%time.Hour == 0 {
		u, n = unitsHour, int(d/time.Hour)
	}
	forms, ok := u[locale]
	if !ok {
		locale, forms = FallbackLocale, u[FallbackLocale]
	}
	w := forms[pluralCategory(locale, n)]
	if w == "" {
		w = forms[catOther]
	}
	// Hebrew says "one hour" / "two hours" with the number in the word.
	if locale == "he" && (n == 1 || n == 2) {
		return w
	}
	return strconv.Itoa(n) + " " + w
}

// Plural categories (CLDR cardinal, integers only).
const (
	catOne = iota
	catTwo
	catFew
	catMany
	catZero
	catOther
	nCats
)

type forms [nCats]string

func f(one, other string) forms { var x forms; x[catOne], x[catOther] = one, other; return x }

func fSlavic(one, few, many string) forms {
	var x forms
	x[catOne], x[catFew], x[catMany], x[catOther] = one, few, many, many
	return x
}

// pluralCategory is the CLDR cardinal rule of locale for a non-negative integer.
func pluralCategory(locale string, n int) int {
	m10, m100 := n%10, n%100
	switch locale {
	case "ru", "uk", "sr":
		switch {
		case m10 == 1 && m100 != 11:
			return catOne
		case m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14):
			return catFew
		}
		return catMany
	case "pl":
		switch {
		case n == 1:
			return catOne
		case m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14):
			return catFew
		}
		return catMany
	case "sk":
		switch {
		case n == 1:
			return catOne
		case n >= 2 && n <= 4:
			return catFew
		}
		return catMany
	case "lt":
		switch {
		case m10 == 1 && (m100 < 11 || m100 > 19):
			return catOne
		case m10 >= 2 && (m100 < 11 || m100 > 19):
			return catFew
		}
		return catMany
	case "lv":
		switch {
		case m10 == 0 || (m100 >= 11 && m100 <= 19):
			return catZero
		case m10 == 1 && m100 != 11:
			return catOne
		}
		return catOther
	case "ro":
		switch {
		case n == 1:
			return catOne
		case n == 0 || (m100 >= 2 && m100 <= 19):
			return catFew
		}
		return catOther
	case "he":
		switch n {
		case 1:
			return catOne
		case 2:
			return catTwo
		}
		return catOther
	case "mk":
		if m10 == 1 && m100 != 11 {
			return catOne
		}
		return catOther
	}
	if n == 1 {
		return catOne
	}
	return catOther
}

func lvForms(one, other, zero string) forms {
	x := f(one, other)
	x[catZero] = zero
	return x
}

func roForms(one, few, other string) forms {
	x := f(one, other)
	x[catFew] = few
	return x
}

func heForms(one, two, other string) forms {
	x := f(one, other)
	x[catTwo] = two
	return x
}

var unitsHour = map[string]forms{
	"en": f("hour", "hours"),
	"bg": f("час", "часа"),
	"fi": f("tunti", "tuntia"),
	"sv": f("timme", "timmar"),
	"ru": fSlavic("час", "часа", "часов"),
	"uk": fSlavic("година", "години", "годин"),
	"he": heForms("שעה אחת", "שעתיים", "שעות"),
	"tr": f("saat", "saat"),
	"mk": f("час", "часа"),
	"el": f("ώρα", "ώρες"),
	"lt": fSlavic("valanda", "valandos", "valandų"),
	"et": f("tund", "tundi"),
	"lv": lvForms("stunda", "stundas", "stundu"),
	"sr": fSlavic("sat", "sata", "sati"),
	"ro": roForms("oră", "ore", "de ore"),
	"sk": fSlavic("hodina", "hodiny", "hodín"),
	"pl": fSlavic("godzina", "godziny", "godzin"),
	"es": f("hora", "horas"),
	"nl": f("uur", "uur"),
}

var unitsMinute = map[string]forms{
	"en": f("minute", "minutes"),
	"bg": f("минута", "минути"),
	"fi": f("minuutti", "minuuttia"),
	"sv": f("minut", "minuter"),
	"ru": fSlavic("минута", "минуты", "минут"),
	"uk": fSlavic("хвилина", "хвилини", "хвилин"),
	"he": heForms("דקה אחת", "שתי דקות", "דקות"),
	"tr": f("dakika", "dakika"),
	"mk": f("минута", "минути"),
	"el": f("λεπτό", "λεπτά"),
	"lt": fSlavic("minutė", "minutės", "minučių"),
	"et": f("minut", "minutit"),
	"lv": lvForms("minūte", "minūtes", "minūšu"),
	"sr": fSlavic("minut", "minuta", "minuta"),
	"ro": roForms("minut", "minute", "de minute"),
	"sk": fSlavic("minúta", "minúty", "minút"),
	"pl": fSlavic("minuta", "minuty", "minut"),
	"es": f("minuto", "minutos"),
	"nl": f("minuut", "minuten"),
}
