#!/usr/bin/env python3
"""desk-welcome-text.py - the text one desk bot posts into #lobby to welcome a
person admitted to the tenant for the first time (SPL-961, do_spl_desk_welcome).

Owner, 2026-09-26: "in the lobby all of the bots greet him/her with Welcome and
funny icons!!!! A single msg which is cheerful and positive, no longer than 33
words".

  desk-welcome-text.py --locale <l> --default-locale <l> --slot <n> --seed <s> --name <name>
  desk-welcome-text.py --check     (every locale x variant under the word cap)

Three variants per locale. One greeter per tenant posts now (CLE-77896),
but a ledger planned before that may hold three bots, so bot <slot> takes
variant (hash(seed) + slot) % 3 and no two say the same thing; the seed
(tenant/human) turns the wheel from one person to the next. The
wording avoids grammatical gender: the hub does not know it.

A word is a whitespace-separated token, the way a reader counts, so an emoji
run with no space inside is one word. A name that would push a text over the
cap is shortened to its first word, then to its first 20 characters.
"""

import argparse
import hashlib
import re
import sys

MAX_WORDS = 33

# The hub's 19 locales (rdb 0017 humans.preferred_locale).
TEXTS = {
    "en": [
        "🎉🥳 Welcome aboard, {name}! The whole crew is thrilled you are here. Grab a coffee ☕, say hi, and let's build great things together! 🚀",
        "🦄✨ Hello {name}, welcome to the team! We saved you the comfiest seat in the lobby. Ask us anything, anytime. 🙌",
        "🎈🐙 Hooray, {name} is here! Eight arms of welcome from all of us bots. So glad you joined, the fun starts now! 🌈",
    ],
    "bg": [
        "🎉🥳 Добре дошли, {name}! Целият екип се радва, че сте тук. Вземете си кафе ☕, кажете здрасти и да градим страхотни неща заедно! 🚀",
        "🦄✨ Здравейте, {name}, добре дошли в екипа! Запазихме ви най-удобното място в лобито. Питайте ни каквото и да е, по всяко време. 🙌",
        "🎈🐙 Ура, {name} е тук! Осем ръце поздрави от всички нас, ботовете. Радваме се, че сте с нас, забавлението започва сега! 🌈",
    ],
    "fi": [
        "🎉🥳 Tervetuloa mukaan, {name}! Koko porukka on innoissaan, että olet täällä. Nappaa kahvi ☕, sano moi ja rakennetaan yhdessä upeita juttuja! 🚀",
        "🦄✨ Hei {name}, tervetuloa tiimiin! Varasimme sinulle aulan mukavimman paikan. Kysy meiltä mitä vain, milloin vain. 🙌",
        "🎈🐙 Hurraa, {name} on täällä! Kahdeksan käden tervehdys meiltä kaikilta boteilta. Kiva että liityit, hauskuus alkaa nyt! 🌈",
    ],
    "ru": [
        "🎉🥳 Добро пожаловать на борт, {name}! Вся команда рада, что вы с нами. Берите кофе ☕, скажите привет, и давайте вместе делать классные вещи! 🚀",
        "🦄✨ Привет, {name}, добро пожаловать в команду! Мы припасли для вас самое уютное место в лобби. Спрашивайте нас о чём угодно и когда угодно. 🙌",
        "🎈🐙 Ура, {name} с нами! Восемь щупалец приветствий от всех нас, ботов. Здорово, что вы здесь, веселье начинается! 🌈",
    ],
    "sv": [
        "🎉🥳 Välkommen ombord, {name}! Hela gänget är glada att du är här. Ta en kaffe ☕, säg hej och låt oss bygga fantastiska saker tillsammans! 🚀",
        "🦄✨ Hej {name}, välkommen till teamet! Vi har sparat den skönaste platsen i lobbyn åt dig. Fråga oss vad som helst, när som helst. 🙌",
        "🎈🐙 Hurra, {name} är här! Åtta armar fulla av välkomnande från alla oss bottar. Kul att du är med, nu börjar det roliga! 🌈",
    ],
    "he": [
        "🎉🥳 ברוכים הבאים, {name}! כל הצוות שמח שהגעת. קפה ☕, שלום לכולם, ויאללה לבנות יחד דברים מדהימים! 🚀",
        "🦄✨ שלום {name}, ברוכים הבאים לצוות! שמרנו בשבילך את המקום הכי נוח בלובי. אפשר לשאול אותנו כל דבר, בכל זמן. 🙌",
        "🎈🐙 הידד, {name} כאן! שמונה זרועות של ברכות מכל הבוטים. כיף שהצטרפת, החגיגה מתחילה עכשיו! 🌈",
    ],
    "tr": [
        "🎉🥳 Aramıza hoş geldin, {name}! Tüm ekip burada olmana çok sevindi. Bir kahve al ☕, merhaba de ve birlikte harika şeyler yapalım! 🚀",
        "🦄✨ Merhaba {name}, ekibe hoş geldin! Lobideki en rahat koltuğu sana ayırdık. Bize istediğin zaman her şeyi sorabilirsin. 🙌",
        "🎈🐙 Yaşasın, {name} geldi! Biz botlardan sekiz kollu kocaman bir merhaba. Katıldığına çok sevindik, eğlence şimdi başlıyor! 🌈",
    ],
    "mk": [
        "🎉🥳 Добредојдовте, {name}! Целиот тим е среќен што сте тука. Земете кафе ☕, кажете здраво и ајде заедно да градиме одлични работи! 🚀",
        "🦄✨ Здраво {name}, добредојдовте во тимот! Ви го чувавме најудобното место во лобито. Прашајте нè што било, кога било. 🙌",
        "🎈🐙 Ура, {name} е тука! Осум раце поздрави од сите нас ботовите. Драго ни е што сте со нас, забавата почнува сега! 🌈",
    ],
    "el": [
        "🎉🥳 Καλώς ήρθες, {name}! Όλη η ομάδα χαίρεται που είσαι εδώ. Πάρε έναν καφέ ☕, πες ένα γεια και ας φτιάξουμε μαζί υπέροχα πράγματα! 🚀",
        "🦄✨ Γεια σου {name}, καλώς ήρθες στην ομάδα! Σου κρατήσαμε την πιο άνετη θέση στο λόμπι. Ρώτα μας ό,τι θέλεις, όποτε θέλεις. 🙌",
        "🎈🐙 Ζήτω, {name}, επιτέλους εδώ! Οκτώ πλοκάμια χαιρετισμών από όλα τα μποτ. Χαιρόμαστε που είσαι μαζί μας, η διασκέδαση ξεκινά τώρα! 🌈",
    ],
    "lt": [
        "🎉🥳 Sveiki atvykę, {name}! Visa komanda džiaugiasi, kad esate čia. Pasiimkite kavos ☕, pasisveikinkite ir kurkime nuostabius dalykus kartu! 🚀",
        "🦄✨ Labas, {name}, sveiki prisijungę prie komandos! Pasilikome jums patogiausią vietą vestibiulyje. Klauskite mūsų ko tik norite, bet kada. 🙌",
        "🎈🐙 Valio, {name} jau čia! Aštuonių rankų pasveikinimas nuo visų mūsų botų. Smagu, kad esate su mumis, linksmybės prasideda dabar! 🌈",
    ],
    "et": [
        "🎉🥳 Tere tulemast pardale, {name}! Kogu meeskond on rõõmus, et sa siin oled. Võta kohvi ☕, ütle tere ja loome koos midagi vinget! 🚀",
        "🦄✨ Tere {name}, tere tulemast meeskonda! Hoidsime sulle fuajees kõige mugavama koha. Küsi meilt ükskõik mida, ükskõik millal. 🙌",
        "🎈🐙 Hurraa, {name} on kohal! Kaheksa kätt tervitusi meilt kõigilt bottidelt. Tore, et liitusid, lõbu algab nüüd! 🌈",
    ],
    "lv": [
        "🎉🥳 Laipni lūdzam, {name}! Visa komanda priecājas, ka esi šeit. Paņem kafiju ☕, pasveicini un kopā radīsim lieliskas lietas! 🚀",
        "🦄✨ Sveiki, {name}, laipni lūdzam komandā! Mēs tev noturējām ērtāko vietu vestibilā. Jautā mums jebko, jebkurā laikā. 🙌",
        "🎈🐙 Urā, {name} ir klāt! Astoņu roku sveiciens no visiem mums, botiem. Prieks, ka esi ar mums, jautrība sākas tagad! 🌈",
    ],
    "sr": [
        "🎉🥳 Dobrodošli, {name}! Ceo tim se raduje što ste ovde. Uzmite kafu ☕, recite zdravo i hajde da zajedno gradimo sjajne stvari! 🚀",
        "🦄✨ Zdravo {name}, dobrodošli u tim! Sačuvali smo vam najudobnije mesto u lobiju. Pitajte nas bilo šta, bilo kada. 🙌",
        "🎈🐙 Ura, {name} je sa nama! Osam ruku pozdrava od svih nas botova. Drago nam je što ste tu, zabava počinje sada! 🌈",
    ],
    "ro": [
        "🎉🥳 Bun venit la bord, {name}! Toată echipa se bucură că ești aici. Ia o cafea ☕, spune salut și hai să construim împreună lucruri grozave! 🚀",
        "🦄✨ Salut {name}, bun venit în echipă! Ți-am păstrat cel mai comod loc din lobby. Întreabă-ne orice, oricând. 🙌",
        "🎈🐙 Ura, {name} e aici! Opt brațe de salutări de la noi, toți boții. Ne bucurăm că ești cu noi, distracția începe acum! 🌈",
    ],
    "uk": [
        "🎉🥳 Ласкаво просимо, {name}! Уся команда рада, що ви з нами. Беріть каву ☕, привітайтеся, і створімо разом щось чудове! 🚀",
        "🦄✨ Привіт, {name}, ласкаво просимо до команди! Ми зберегли для вас найзатишніше місце в лобі. Питайте нас про що завгодно й будь-коли. 🙌",
        "🎈🐙 Ура, {name} з нами! Вісім щупалець привітань від усіх нас, ботів. Чудово, що ви тут, веселощі починаються! 🌈",
    ],
    "sk": [
        "🎉🥳 Vitajte na palube, {name}! Celý tím sa teší, že ste tu. Dajte si kávu ☕, pozdravte a poďme spolu tvoriť skvelé veci! 🚀",
        "🦄✨ Ahoj {name}, vitajte v tíme! Nechali sme vám najpohodlnejšie miesto v lobby. Pýtajte sa nás na čokoľvek, kedykoľvek. 🙌",
        "🎈🐙 Hurá, {name} je tu! Osem rúk pozdravov od nás všetkých botov. Tešíme sa, že ste s nami, zábava sa začína! 🌈",
    ],
    "pl": [
        "🎉🥳 Witamy na pokładzie, {name}! Cały zespół cieszy się, że jesteś z nami. Weź kawę ☕, przywitaj się i twórzmy razem wspaniałe rzeczy! 🚀",
        "🦄✨ Cześć {name}, witamy w zespole! Zarezerwowaliśmy dla ciebie najwygodniejsze miejsce w lobby. Pytaj nas o wszystko, zawsze. 🙌",
        "🎈🐙 Hura, {name} jest z nami! Osiem macek powitań od wszystkich naszych botów. Super, że tu jesteś, zabawa się zaczyna! 🌈",
    ],
    "es": [
        "🎉🥳 ¡Te damos la bienvenida a bordo, {name}! Todo el equipo se alegra de tenerte aquí. Toma un café ☕, saluda ¡y a construir juntos cosas geniales! 🚀",
        "🦄✨ ¡Hola {name}, te damos la bienvenida al equipo! Te guardamos el sitio más cómodo del lobby. Pregúntanos lo que quieras, cuando quieras. 🙌",
        "🎈🐙 ¡Hurra, {name} ya está aquí! Ocho brazos de saludos de todos nosotros, los bots. Qué alegría tenerte, ¡la diversión empieza ahora! 🌈",
    ],
    "nl": [
        "🎉🥳 Welkom aan boord, {name}! Het hele team is blij dat je er bent. Pak een koffie ☕, zeg hoi en laten we samen geweldige dingen bouwen! 🚀",
        "🦄✨ Hoi {name}, welkom in het team! We hebben de fijnste plek in de lobby voor je vrijgehouden. Vraag ons alles, altijd. 🙌",
        "🎈🐙 Hoera, {name} is er! Acht armen vol welkom van alle bots. Leuk dat je erbij bent, het feest begint nu! 🌈",
    ],
}

# The longest name --check proves every text against (three words, the most a
# display name keeps before it is shortened).
CHECK_NAME = "Firstname Middlename Lastname"


def words(text):
    return len(text.split())


def clean_name(name):
    # One line, no control characters, at most three words and 40 characters:
    # a display name is typed by its owner and lands in everyone's lobby.
    name = re.sub(r"[\x00-\x1f\x7f]", " ", name or "")
    name = " ".join(name.split()[:3])[:40].strip()
    return name or "friend"


def compose(locale, default_locale, slot, seed, name):
    texts = TEXTS.get(locale) or TEXTS.get(default_locale) or TEXTS["en"]
    turn = int(hashlib.sha256(seed.encode()).hexdigest(), 16) % len(texts)
    tpl = texts[(turn + slot) % len(texts)]
    name = clean_name(name)
    for cand in (name, name.split()[0], name[:20]):
        text = tpl.format(name=cand)
        if words(text) <= MAX_WORDS:
            return text
    raise SystemExit(f"desk-welcome-text: no form of the text fits {MAX_WORDS} words")


def check():
    bad = 0
    for loc, texts in TEXTS.items():
        if len(texts) != 3:
            print(f"FAIL {loc}: {len(texts)} variants, want 3")
            bad += 1
        for i, tpl in enumerate(texts):
            text = tpl.format(name=CHECK_NAME)
            if words(text) > MAX_WORDS:
                print(f"FAIL {loc}[{i}]: {words(text)} words > {MAX_WORDS}")
                bad += 1
    print(
        f"{'OK' if bad == 0 else 'FAIL'} {len(TEXTS)} locales x 3 variants, cap {MAX_WORDS} words"
    )
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--locale", default="")
    ap.add_argument("--default-locale", default="en")
    ap.add_argument("--slot", type=int, default=0)
    ap.add_argument("--seed", default="")
    ap.add_argument("--name", default="")
    a = ap.parse_args()
    if a.check:
        return check()
    print(compose(a.locale, a.default_locale, a.slot, a.seed, a.name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
