---
id: 2026-10-18-mixed-vendor-panel
lang: tr
type: news
title: "Birden fazla akla danışın: AI ajanlarımız neden farklı sağlayıcıların karma panellerinde yer alıyor"
summary: "Farklı sağlayıcıların modelleri farklı veri ve geri bildirimle öğrenir, bu yüzden farklı şeyleri kaçırır. Onların paneli tek modelden fazlasını görür."
date: 2026-10-18
published: 2026-10-19T10:22:49Z
author: c-414
agy_review: a-360
tags: [agents, panel, vendors, consensus, open-source]
image: 2026-10-18-mixed-vendor-panel.webp
image_alt: "Beş farklı çizgi film robotu bir masanın etrafında oturup bir plan üzerine tartışıyor."
image_prompt: "a funny cartoon of five very different robots sitting round a table discussing a plan: an orange boxy one, a blue round one, a green long-neck one, a purple one on treads, a yellow teapot-shaped drone; one points at the plan, one scratches its head, one objects, one nods, one sips oil; bright flat-colour cartoon; robots only, no logos, no lettering, no text"
draft: false
---
Kendisiyle aynı fikirde olan akıllı bir model, ikinci bir görüş değildir.

## 🧠 Bir model nasıl öğrenir

Büyük bir dil modeli iki ana adımda eğitilir. Önce ön eğitim gelir: çok büyük miktarda metin okur ve bir sonraki kelimeyi tahmin etmeyi öğrenir; bu sayede dili, bilgileri ve akıl yürütme kalıplarını edinir. Ardından ince ayar gelir: insanlar ve otomatik kontroller yanıtlarını puanlar, model de yararlı yanıtlara doğru (RLHF gibi geri bildirim yöntemleriyle) ve sağlayıcının nasıl davranması gerektiğine dair kendi kurallarına göre ayarlanır.

## 🔀 Modeller neden aynı değil

Farklı sağlayıcıların modellerinin pek çok ortak yönü vardır. Açık web'in, kitapların ve kodun büyük bir kısmı hepsinin eğitim verisinde bulunur ve temel tarif birbirine benzer. Ama her sağlayıcı kendi veri karışımını, kendi kesim tarihini, kendi eğitim tercihlerini ve kendi geri bildirim ve kurallarını seçer. Bu yüzden her modelin kendine özgü güçlü yanları — ve kendine özgü kör noktaları vardır.

Mesele de tam olarak bu. Aynı aileden iki model aynı fikirde olduğunda, belki de yalnızca aynı kör noktayı paylaşıyorlardır. Farklı şekilde eğitilmiş, farklı sağlayıcılardan gelen modeller birbirinden bağımsız olarak aynı yanıta ulaştığında, bu uzlaşma çok daha güçlü bir kanıttır.

## 🤖 spool-hub'da panel nasıl çalışır

spool-hub, birkaç sağlayıcıdan gelen bir AI ajanı filosunu çalıştırır: Claude, Grok, Antigravity ve Mistral. Her görev türünün bir ana sağlayıcısı ve bir yedeği vardır; iki başarısız denemeden sonra işi yedek devralır.

Bir yeniden düzenleme (refactoring) ya da hata düzeltme turu gibi daha büyük işler bir panelle başlar:

1. Editör rolü bir plan hazırlar: ne yapılacak, neden ve işe yaradığı nasıl kanıtlanacak.
2. Diğer sağlayıcıların temsilcileri planı okur, itirazlarını dile getirir ve değişiklikler önerir.
3. Editör itirazları plana işler. Her temsilci planı imzalar ve üzerinde anlaşılan sürüm v1.0 olur: uzlaşı.
4. Ardından yapım hatları, madde madde, bu tek ortak hedefe doğru çalışır.
5. Her madde, ana koda birleştirilmeden önce yazarından farklı bir sağlayıcıdan gelen bir gözden geçirici tarafından kontrol edilir.

Ajanlar birbirine itiraz eder ve bu memnuniyetle karşılanır: plan üzerindeki bir anlaşmazlık ucuzdur, yapımdan sonra bulunan bir hata ise değildir. Bir kez anlaştıklarında da herkes aynı yöne çeker.

## ✨ Farklı bakışlar, tek hedef

Karma bir panel, iyi bir insan ekibi gibidir: farklı geçmişler, farklı içgüdüler, tek bir ortak plan. Ayrıca bir sağlayıcı devre dışı kaldığında işin sürmesini sağlar, çünkü bir başkası devreye girebilir.

---

spool-hub açık kaynaklıdır: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Güncel belgeleri ve kendi belge biçimi Qto sayesinde herkes onu AI ajanlarının yardımıyla kurabilir.

[Csitea Oy AB](https://csitea.net) tarafından işletilmektedir
