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
image_alt: "Bir ajanın şirketin bulut sürücüsünde vergi dosyaları aradığı bir terminal penceresi; hizmet hesabının adı, yollar, kimlikler ve klasör adları siyah kutularla kapatılmış."
image_prompt: "a screenshot of the agent's terminal and its side panel on a desktop, private details covered with solid black boxes, cropped to 16:9; not generated"
---
İtiraf ediyorum: kötü bir işletme sahibiyim. Şirketimin vergilerini takip edemiyorum. Disiplini ve otomasyonu defalarca denedim; hiçbiri kalıcı olmadı.

Her şeyi tek bir yerde görünce düşündüm: muhtemelen şirketim için fazla vergi ödüyorum. LinkedIn'de: [Paisunut julkkari](https://lnkd.in/p/dNWaAK-P).

## 1. 🖥️ Kendi makinem, tarayıcıdan yönetim

Bir ajanı kendi dizüstü ya da masaüstü bilgisayarınızda çalıştırın ve Spool-Hub'ın web arayüzünden yönetin. MCP ve Firefox (ya da herhangi bir MCP tarayıcısı) ile erişiminiz olan her sistemden bilgi çeker. Burada: Fin Vergi İdaresi'nin e-hizmeti Vero.fi (vero = vergi).

## 2. 📂 Ne oldu

Şirketimin özel çalışma alanında peşin vergiyi sordum, sonra ajandan masaüstümde bir tarayıcı açmasını istedim.

- Girişi kendim yaptım; ajan kimlik bilgilerini asla yazmaz, okumaz ya da saklamaz.
- Yılın kararlarını, mektuplarını ve ödeme bilgilerini çekti; bunları ve eski vergi belgelerini bulut sürücüsünde aya ve türe göre dosyaladı.
- Her konu için bir kayıt istedim; ajanlar muhasebeciye gerekçeli bir e-posta yazdı.
- Kısa mesajlarla yönettim; belgeler gizli kaldı.

## 3. ⏱️ Önce ve sonra

Elle, benim tahminim (ölçülmedi): 5-7 saat. Yaklaşık 30 belgeyi dosyalamak (her biri 3-5 dk), ödemeler ve son tarihler (1-2 sa), eski dosyalar (1 sa), e-posta (1 sa).

Şimdi: 96 kısa mesaj, yaklaşık altı giriş, yaklaşık 3 saatlik kurulum (UTC, 24.11.2026):

| aşama | saat |
|---|---|
| ilk soru | 14.23 |
| ajan talebi, giriş | 14.59-15.12 |
| kendi depo, belgeleri çekme | 15.56-17.22 |
| 30/32 belge sürücüde | 17.45 |
| e-posta hazır | 18.10 |

Talepten bitişe: 2 sa 46 dk; sorudan e-postaya: 3 sa 47 dk.

## 4. 📅 Haftalık rapor

Haftalık bir rapor istedim: yeni belgeler, son tarihler, açık sorular. Kod hazır, henüz zamanlanmadı.

## 5. 🏢 Csitea Oy

Bir danışmanlık şirketi olan Csitea Oy, Spool-Hub'ı finanse ediyor ve geliştiriyor. Bulut ve DevOps danışmanlığı (AWS, Google Cloud, Kubernetes, Terraform, Python arka uçları) ve bir çevrimiçi mağaza hizmeti sunuyor: [csitea.net](https://csitea.net).

## 6. 🔧 Teknik kısım: hizmet hesabı

Bulut sürücüsünde ajan benim olarak değil, şirketin yedekleme hizmet hesabı olarak çalışır. Yalnızca kendisiyle paylaşılan klasörleri görür: vergiler için tüm mali belgelerin tek bir kök klasörü; ajan orada yıl/ay/vero/tür yapısını kurdu. Anahtar git'te değil, makinede kalır; kod anahtarı ve klasörü adlandırılmış değişkenlerden okur.

## 7. 🏭 Açık kaynak

Spool Hub açık kaynaklıdır (GNU AGPL v3): kendi örneğinizi bulutta ya da `docker compose` ile çalıştırın: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl). Demo hesap mı istiyorsunuz? İletişim: [csitea.net](https://csitea.net).
