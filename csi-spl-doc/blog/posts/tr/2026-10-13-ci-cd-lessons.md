---
id: 2026-10-13-ci-cd-lessons
lang: tr
type: news
title: "Dünkü CI/CD sorunlarının bize öğrettikleri"
summary: "CI/CD'yi düzeltmek ve testleri optimize etmek için yeni özellikleri duraklatmak, süreleri kısalttı ve gelecekteki teslimatı hızlandırdı."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Robotik kollar ve yeşil onay işaretleri içeren fütüristik otomatik sürekli entegrasyon ve dağıtım işlem hattı."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
12 Ekim 2026 tarihinde sürekli entegrasyon hattımız ciddi aksaklıklarla karşılaştı. Ana dal yeşilden çok kırmızıydı: master dalındaki 22 tamamlanmış kalite kontrol çalıştırmasından 10'u yeşil, 12'si kırmızıydı; diğer 36 çalıştırma ise daha yeni gönderimlerle değiştirildiği için iptal edildi. Geri bildirim almak gönderim başına 47 ila 61 dakika sürüyordu ve web arayüzünün dev ile prd ortamlarındaki dağıtımı yaklaşık iki saat boyunca durdu. Önemli olan nokta, kırmızı çalıştırmaların çoğunun ürün hatalarından değil, kararsız testlerden ve yarış koşullarından kaynaklanmasıydı.

Ana dal bozulduğunda filodaki tüm aktif çalışma hatları bundan etkilenir. Kırmızı bir dala yeni değişiklikler göndermek geliştiricilerin önünü kapatır ve hataları katlar. Proje sahibi, sürekli entegrasyon stabil ve hızlı hale gelene kadar tüm yeni özellik geliştirmelerini ve hazırlık niteliğindeki yeniden yapılandırmaları duraklatma kararı aldı. Bu, ilerleyen günlerde çok daha hızlı ve güvenilir çalışabilmek adına daha yavaş geçen bir sabahı kabul etmek anlamına geliyordu.

Gerçek darboğazlara odaklandık. İlk olarak, test işlerinin GitHub tarafından barındırılan çalıştırıcılara taşınması, tam çalıştırma sürelerini yaklaşık 50 dakikadan 30.4 dakikalık medyana (n=12) indirdi ve kuyruk bekleme sürelerini 19 dakikadan 0.1 dakikanın altına düşürdü. İkinci olarak, kalite kapısı yalnızca bir gönderimin dokunduğu kısımları test edecek şekilde güncellendi; her işin kendi son başarılı çalıştırması referans alındı. Üçüncü olarak, kod gönderilmeden önce çalıştırılan hızlı yerel denetimler basit hataları saniyeler içinde yakaladı. Çalıştırıcı değişiminin ardından gelen hedefe yönelik yeniden yapılandırma turları (r8 ila r14), en yavaş testlerden dakikalar kazandırdı; örneğin mobil tarayıcı testi 164 saniyeden 63 saniyeye indirildi (n=3). Hata analiz biçimimizi de değiştirdik: hataları çalıştırma bazında değil iş bazında saymak, 42 kırmızı çalıştırmanın genellikle sadece altı temel nedenden kaynaklandığını ortaya koydu.

Bu deneyim, sürekli entegrasyon için temel en iyi uygulamaları pekiştirdi:
1. Önce ölçün: Çözüm önermeden önce gerçek bekleme süresini ölçün ve işlemleri sayın.
2. Her hızlandırmayı bir sayma testi ve eski davranışta başarısız olan bir kontrolle kanıtlayın.
3. Ana dalın temiz kalması için ucuz denetimleri göndermeden önce yerel olarak çalıştırın.
4. Kasıtlı test hatalarını ve kontrolleri geçici dallarda tutun, asla master dalına almayın.
5. Kararsız testlere en yüksek öncelikle gerçek birer kusur olarak yaklaşın.
6. Belirli örneklem boyutlarıyla küçük, ölçülü turlar halinde sürekli yeniden yapılandırın.
7. Başarısız olan her işi derhal tek bir sorumluya atayın.

Sürekli entegrasyonu iyileştirmek, gelecekteki özelliklerin kullanıma sunulmasını doğrudan hızlandırır. Daha kısa geri bildirim döngüleri ve güvenilir yeşil dal, hız ve güven sağlar.
