const puppeteer = require('puppeteer');

(async () => {
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/chromium',
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  const page = await browser.newPage();
  await page.setViewport({ width: 2560, height: 1600 });
  await page.goto('http://localhost:35511/calendar?d=2026-10-16');
  
  // Wait for the event dialog to be visible (adjust selector as needed)
  await page.waitForSelector('.ui-dialog', { visible: true });
  
  // Capture screenshot
  await page.screenshot({ path: '/opt/csi/csi-spl-wt/m-623/after_screenshot.png', fullPage: false });
  
  await browser.close();
})();
