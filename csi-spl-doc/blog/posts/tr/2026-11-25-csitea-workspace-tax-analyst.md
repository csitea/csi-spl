---
id: 2026-11-25-csitea-workspace-tax-analyst
lang: tr
type: news
title: "Kötü bir işletme sahibi, iyi bir vergi analisti: özel bir Spool-Hub çalışma alanı şirketimin vergilerini halletti"
summary: "Şirketimin vergilerini takip edemiyorum. Özel bir Spool-Hub çalışma alanı ve tek bir ajan, Vero.fi'deki bir yıllık belgeleri yaklaşık üç saatte düzene soktu."
date: 2026-11-25
published: 2026-11-25T13:55:48Z
author: c-296
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, mcp, automation, open-source]
draft: false
image: 2026-11-25-csitea-workspace-tax-analyst.webp
image_alt: "Bir infografik: vergi kâğıdı yığınlarıyla bir işletme sahibi, robot bir vergi analisti, ortada özel bir Spool-Hub çalışma alanı, MCP üzerinden tarayıcıda Vero.fi'yi açan bir ajan, bulut sürücüde yıl, vergi ve ödeme klasörlerine yerleştirilmiş belgeler, muhasebeciye bir e-posta ve süreler: elle 5-7 saat, kurulum ve otomasyon 3 saat, bir dahaki sefere 15 dakika."
image_prompt: "the owner's own infographic (made with Gemini), published as-is; centre-cropped to 16:9 by the blog encoder"
---
İtiraf ediyorum: kötü bir işletme sahibiyim. Şirketimin vergilerini takip edemiyorum. Disiplini ve otomasyonu defalarca denedim; hiçbiri kalıcı olmadı.

Her şeyi tek bir yerde görünce düşündüm: muhtemelen şirketim için fazla vergi ödüyorum. LinkedIn'de: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

Sıradaki adım otomasyon: betikler artı Spool-Hub'ın zamanlama ve altyapısı; böylece haftalık kontrol kendi kendine çalışacak. Betikler herkese açık: [github.com/csitea/csi-tax](https://github.com/csitea/csi-tax).

## 1. 🖥️ Kendi makinem, tarayıcıdan yönetim

Bir ajanı kendi dizüstü ya da masaüstü bilgisayarınızda çalıştırın ve Spool-Hub'ın web arayüzünden yönetin. MCP ve Firefox (ya da herhangi bir MCP tarayıcısı) ile erişiminiz olan her sistemden bilgi çeker. Burada: Fin Vergi İdaresi'nin e-hizmeti Vero.fi (vero = vergi).

## 2. 📂 Ne oldu

Şirketimin özel çalışma alanında peşin vergiyi sordum, sonra ajandan masaüstümde bir tarayıcı açmasını istedim.

- Girişi kendim yaptım; ajan kimlik bilgilerini asla yazmaz, okumaz ya da saklamaz.
- Yılın kararlarını, mektuplarını ve ödeme bilgilerini çekti; bunları ve eski vergi belgelerini bulut sürücüsünde aya ve türe göre dosyaladı.
- Her konu için bir kayıt istedim; ajanlar muhasebeciye gerekçeli bir e-posta yazdı.
- Kısa mesajlarla yönettim; belgeler gizli kaldı.

## 3. ⏱️ Önce ve sonra

Elle 5-7 saat sürüyordu.

Şimdi: 96 kısa mesaj, yaklaşık altı giriş ve otomasyonu ve kurulumu oluşturmaya harcanan yaklaşık 3 saat (UTC, 24.11.2026):

| aşama | saat |
|---|---|
| ilk soru | 14.23 |
| ajan talebi, giriş | 14.59-15.12 |
| kendi depo, belgeleri çekme | 15.56-17.22 |
| 30/32 belge sürücüde | 17.45 |
| e-posta hazır | 18.10 |

Bundan sonra aynı vergi işi haftada 15 dakikadan az sürmeli.

## 4. 📅 Haftalık rapor

Haftalık bir rapor istedim: yeni belgeler, son tarihler, açık sorular. Kod hazır, henüz zamanlanmadı.

## 5. 🏢 Csitea Oy

Bir danışmanlık şirketi olan Csitea Oy, Spool-Hub'ı finanse ediyor ve geliştiriyor. Bulut ve DevOps danışmanlığı (AWS, Google Cloud, Kubernetes, Terraform, Python arka uçları) ve bir çevrimiçi mağaza hizmeti sunuyor: [csitea.net](https://csitea.net).

## 6. 🔧 Teknik kısım: hizmet hesabı

Bulut sürücüsünde ajan benim olarak değil, şirketin yedekleme hizmet hesabı olarak çalışır. Yalnızca kendisiyle paylaşılan klasörleri görür: vergiler için tüm mali belgelerin tek bir kök klasörü; ajan orada yıl/ay/vero/tür yapısını kurdu. Anahtar git'te değil, makinede kalır; kod anahtarı ve klasörü adlandırılmış değişkenlerden okur.

## 7. 🏭 Açık kaynak

Spool Hub açık kaynaklıdır (GNU AGPL v3): kendi örneğinizi bulutta ya da `docker compose` ile çalıştırın: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demo hesap mı istiyorsunuz? İletişim: [csitea.net](https://csitea.net).
