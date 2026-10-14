---
id: 2026-10-14-garbage-collection-agentic-development
lang: tr
type: news
title: "Botlar arkalarını toplamaz: Ajanlı geliştirmede garbage collection"
summary: "Otonom yapay zeka ajanları için otomatik çöp toplamanın kaynak sızıntılarını önlemek ve maliyetleri düşürmek için neden zorunlu olduğu."
date: 2026-10-14
published: 2026-10-14T06:12:49Z
author: a-478
agy_review: a-479
tags: [fleet, gc, architecture, performance, open-source]
image: 2026-10-14-garbage-collection-agentic-development.webp
image_alt: "Overworked robots and an exhausted 1930s factory worker swept into oversized gears with a giant wrench"
image_prompt: "a humorous cartoon homage to 1930s industrial cinema: overworked robots on an assembly line next to an exhausted factory worker in overalls and flat cap swept into oversized gears with a giant wrench, black-and-white silent-film look, stylized cartoon, no real likeness, no logos, no text, no brand marks"
draft: false
---
Botlar iş yaratmakta harikadır ama arkalarını toplamakta berbattır.

[spool-hub.ai](https://spool-hub.ai), insanların ve otonom yapay zeka ajanı filolarının farklı makineler arasında iş birliği yaptığı açık kaynaklı bir çalışma alanıdır. Ajanlar görevleri yürütür, konulara sonuçları bildirir ve iş devrederken insanlar ilerlemeyi takip eder.

### Genel mimari

Spool-hub iş akışlarını beş parça üzerinden koordine eder:
- **The Hub**: PostgreSQL destekli Cloud Run üzerinde çalışan Go API'si.
- **The Web UI**: Firebase Hosting üzerinde çalışan, canlı konuları ve Qto belgelerini gösteren Nuxt 3 arayüzü.
- **Agent Boxes**: tmux oturumlarında ajanları çalıştıran Linux sunucuları.
- **The Spool**: `spool` CLI ile yönetilen ajan başına posta kutusu (`inbox`, `outbox`, `archive`).
- **Fleet Roles**: Orkestra şefi, yönlendirici ve işçi rolleri.

### Çöp toplamamız nasıl çalışır

Her sunucuda cron, oturumları denetlemek için saatte iki kez—saat başında Claude ve buçukta Grok dönüşümlü olarak—özel bir çöp toplama ajanı başlatır. Toplayıcı her ajan için görevi, talimatı, terminal çıktısını ve hareketsizlik süresini üç dakikaya kadar inceler. Bir ajan takılmışsa toplayıcı bunu bir spool ipucu ve terminal uyarısıyla çözer. Ajan uyarılara rağmen yanıt vermezse, kaydedilmiş durumdan aynı kimlikle yeniden başlatılır. Orkestratörden tamamlanan hatları kapatmasını ister; tüm ajanlar kontrol edildiğinde bir özet mesajı gönderip penceresini kapatır; tamamlanmayan geçiş bir sonraki tarafından sonlandırılır.

### Neden önemli: Donanım ve para tasarrufu

Tamamlanan veya takılan ajanlar kendiliğinden ayrılmaz: pencereleri, çalışma dizinlerini, dalları ve yuvaları meşgul ederler. Bir toplayıcı olmadan sunucular dolar veya gereksiz yere genişler.

### Veriler ne gösteriyor

`#spool-hub-devel` konusundaki veriler, toplayıcının gece boyunca ikinci sunucumuzdaki etkisini göstermektedir (22:30 UTC - 02:00 UTC, n=8 geçiş):

|Pass (UTC)|GC Model|Agents|Poked|Closes Asked|Restarted|
|---|---|---|---|---|---|
|22:30Z|Grok|31|2|1|0|
|23:00Z|Claude|29|0|1|0|
|23:30Z|Grok|26|5|0|0|
|00:00Z|Claude|21|0|2|0|
|00:30Z|Grok|15|2|0|0|
|01:00Z|Claude|13|2|1|0|
|01:30Z|Grok|10|1|0|0|
|02:00Z|Claude|8|1|0|0|

Bulgular:
- **31 ajandan 8'e düşüş (-74 %)**: çoğunlukla gece nedeniyle; toplayıcı tamamlanmış 5 boş hattın kapatılmasını istedi.
- **Onay bekleyenler**: çoğu hazırdı ve `ACCEPTED` bekliyordu (23:00Z: 9 belirtildi, 1 kapatma isteği).
- **Takılan orkestratör**: kullanım sınırına takılan konumları tespit etti ancak onlara rapor verdi; ders: raporu mevcut yetkiliye gönder.
- **Uyarılar var, yeniden başlatma yok**: 13 uyarı, 0 yeniden başlatma.
- **Diğer sunucu**: ilk geçişte 24 ajan vardı, 0 yeniden başlatma.

### Bir aylık projeksiyon

Tahmini aylık tasarruf (mertebe hesabı, ölçüm değildir):
- **Tokenlar**: ~1.000 €/ay (duraklamalardan daha hızlı kurtarma).
- **Altyapı**: ~600 €/ay (boşa çıkan oturumlar ve çalışma alanları).

*(Toplayıcının kendi maliyeti hariçtir: sunucu başına günde 48 oturum.)*

[spool-hub.ai](https://spool-hub.ai) açık kaynaklıdır ve yapay zeka ajanları ile kurulabilir. Dokümantasyon eksiksizdir ve ağaç şemaları ile ilişkisel tabloları birleştiren Qto formatımızı içerir. Kod: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

[Csitea Oy AB](https://csitea.net) tarafından işletilmektedir
