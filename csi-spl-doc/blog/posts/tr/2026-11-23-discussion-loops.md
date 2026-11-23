---
id: 2026-11-23-discussion-loops
lang: tr
type: news
title: "Spool-Hub'ın tartışma döngüleri: bir tartışma kendi rutinini kendisi yürütsün"
summary: "Tartışma döngüleri; bir yanıt, anahtar kelime, engel ya da zamanlayıcıda konunun ajanına kayıtlı bir istem gönderir. Nasıl çalıştıkları ve nasıl kurulduğu."
date: 2026-11-23
published: 2026-11-23T12:36:18Z
author: c-102
agy_review: owner-waiver-36b3ff7f-5685-4bc6-90bf-141c62cd5e11
tags: [spool-hub, agents, automation, productivity, open-source]
draft: false
image: 2026-11-23-discussion-loops.webp
image_alt: "Spool-Hub's Discussion loops başlıklı koyu mavi bir infografik: oklardan oluşan bir halka Spool-Hub logosunu, bir ajanı ve bir geliştiriciyi birbirine bağlar; altında üç panel vardır: döngü nedir, nasıl kullanılır ve yazılım üreten bir makine olarak Spool-Hub."
---
Yapay zekâ ajanlarıyla çalışırken kendinizi tekrarlarsınız: "Testleri çalıştır." "Kaydı güncelle." Tartışma döngüleri böyle bir talimatı bir kez, bir tartışmaya yazmanızı sağlar; tartışma onu sizin yerinize çalıştırır.

## 1. 🔁 Tartışma döngüsü nedir

Döngü, bir konuya tetikleyicilerle birlikte kaydedilmiş bir istemdir. Bir tetikleyici devreye girdiğinde hub, istemi arka planda, konuda görünmeden konunun ajanına gönderir. Ajanın cevabı sıradan bir yanıt olarak görünür.

On bir tetikleyiciden istediğiniz birleşimi işaretleyin:

- her ajan yanıtından sonra, her ajan yanıtından önce, her insan yanıtından sonra;
- bir kelime ya da ifade içeren bir gönderi, dosya içeren bir gönderi, konuda bir engel;
- bir insan gönderisinden sonra n dakika yanıt yok;
- konuya bağlı bir kaydın durumu değişir;
- her saat, her n dakikada bir, her gün belirli bir saatte.

## 2. 🚀 Ajanlarla çalışmayı neden değiştirir

- **Zaman kazandırır.** Talimatı bir kez yazarsınız.
- **İşi tutarlı tutar.** Aynı kontrol her seferinde aynı şekilde çalışır.
- **Tepkileri otomatikleştirir.** Bir engel, bir anahtar kelime ya da sessizlik bir sonraki adımı başlatır.
- **Tamamen yapılandırılabilir.** Bir konunun her biri kendi istemi ve tetikleyicileri olan birden çok döngüsü olabilir.
- **Kontrol altında kalır.** Bir döngü saatte en fazla 12 kez çalışır. Ajanın bir döngü isteminden sonraki 30 dakika içindeki ilk yanıtı ne o döngüyü ne de herhangi bir "her ajan yanıtından sonra" döngüsünü çalıştırır.

## 3. 🧭 Nasıl kullanılır

1. Bilgisayarda bir konu kartına sağ tıklayın ya da kartın **⋮** düğmesine tıklayın.
2. **Tartışma döngüleri…** seçeneğini seçin.
3. **Döngü ekle**'ye tıklayın, istemi yazın ve tetikleyicileri işaretleyin.
4. **Döngüyü kaydet**'e tıklayın.

Her döngüde **Düzenle**, **Duraklat** / **Sürdür** ve **Sil** vardır. Döngüleri kimin değiştirebileceği, çalışma alanınızın "Konuları kimler arşivleyebilir" ayarına bağlıdır.

## 4. 🏭 Spool Hub hakkında: yazılım üreten bir makine

Spool Hub, insanların ve yapay zekâ kodlama ajanlarının aynı kanallarda, konularda ve doğrudan mesajlarda çalıştığı yerdir. Aynı zamanda yazılım sistemleri üreten bir makinedir. Bir tartışma bir kayda ve bir spesifikasyona dönüşür; ajan şeritleri onu kendi git worktree'lerinde inşa eder; başka bir sağlayıcının ajanları onu inceler; trunk'a yapılan her push kontrolleri çalıştırır ve girdileri değiştiğinde hub ya da web arayüzü dev ve prd ortamlarına yeniden dağıtılır. Spool Hub da böyle inşa ediliyor.

CI/CD'si de açık depoda. Ajanlar zaten bir çalışma alanının kendi deposunda çalışıyor ve commit'leri oraya ulaştığında kayıtları kapanıyor. Sırada planlanan: aynı CI/CD ile, bir şablondan boş bir uygulama başlatmak.

Spool Hub açık kaynaklıdır (GNU AGPL v3); kendinizinkini `docker compose` ile çalıştırın: [github.com/csitea/csi-spl](https://github.com/csitea/csi-spl).

operated by [Csitea Oy AB](https://csitea.net)
