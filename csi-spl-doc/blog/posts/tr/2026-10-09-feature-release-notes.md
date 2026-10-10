---
id: 2026-10-09-feature-release-notes
lang: tr
type: news
title: "Sürüm Notlarını Kolayca Keşfedin"
summary: "Yeni Sürüm notları iletişim kutusu ile uygulama içindeki en son 30 değişikliği ve güncellemeyi takip edin."
date: 2026-10-09
published: 2026-10-09T14:38:00Z
author: a-686
agy_review: a-760
tags: [feature, release-notes]
draft: false
image: 2026-10-09-feature-release-notes.webp
image_alt: "Temiz bir kullanıcı arayüzünde sürümleri ve sürüm notlarını gösteren soyut, modern bir dijital değişiklik günlüğü ve güncelleme izleyicisi"
image_prompt: "An abstract, modern digital changelog and update tracker, showing versions and release notes in a clean UI"
---
**Nedir**

Sürüm notları iletişim kutusu, özel bir değişiklik günlüğü izleyicisidir. Commit mesajı alt bilgilerinden (trailers) sade dilde ve teknik sürüm notlarını çıkarır ve bunları doğrudan çalışma alanında sunar.

**Neden kullanılmalı**

Günlük kullanıcılardan mühendislere kadar herkesi; git günlüklerini veya harici değişiklik izleyicilerini eşelemeye gerek kalmadan neyin, nasıl ve neden değiştiği hakkında bilgilendirir.

**Nasıl kullanılır**

Sol bölmenin altındaki uygulama sürümüne (veya telefonda durum çubuğuna) tıklayın ve 'Sürüm notları'nı seçin. En son 30 değişikliği gösteren bir iletişim kutusu açılır. Hem sade kelimelerle hem de teknik terimlerle tam açıklamasını okumak için herhangi bir değişikliğe tıklayın. Masaüstünde öğeler arasında gezinmek için `j` ve `k` tuşlarını kullanabilir veya daha eski kayıtları görmek için alt kısımdaki 'Eski sürümleri yükle'ye tıklayabilirsiniz. Her bir not, kalıcı bir `/releases/<ref>` bağlantısı aracılığıyla paylaşılabilir.

**Eski yöntem**

Değişiklikler genellikle harici belgelerde manuel olarak izleniyordu veya kullanıcılar yeni özellikleri ve düzeltmeleri anlamak için ayrı duyurulara ve ham git geçmişlerine bel bağlamak zorundaydı. 

**Yeni yöntem**

Sürüm notları artık otomatik olarak entegre ediliyor. Geçerli her değişiklik doğrudan commit alt bilgilerinden (trailers) doldurulur; bu da değişiklik günlüğünün her zaman doğru olmasını ve okunaklı bir tablo düzeninde tam olarak çalıştıkları yerde herkesin erişimine açık olmasını sağlar.
