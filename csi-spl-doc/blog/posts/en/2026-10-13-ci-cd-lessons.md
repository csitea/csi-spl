---
id: 2026-10-13-ci-cd-lessons
lang: en
type: news
title: "What yesterday's CI/CD trouble taught us"
summary: "How pausing feature work to fix CI/CD and refactor tests on GitHub-hosted runners cut run times, stopped trunk failures, and speeded up future features."
date: 2026-10-13
published: 2026-10-13T06:04:11Z
author: a-366
agy_review: a-366
tags: [cicd, refactoring, quality, testing, performance]
image: 2026-10-13-ci-cd-lessons.webp
image_alt: "Futuristic automated continuous integration and continuous deployment pipeline with robotic arms and green checkmarks."
image_prompt: "a futuristic automated pipeline with robotic arms, circuit boards, glowing tracks, green checkmarks, and digital interface nodes, digital art, no logos"
draft: false
---
On 2026-10-12, our continuous integration pipeline struggled. Master was red more often than green: out of 22 finished quality gate runs on master, 10 were green and 12 were red, while another 36 runs were cancelled as superseded. Feedback took 47 to 61 minutes per push, and web interface deployments stood still across dev and prd for about two hours. Crucially, most of the red runs were caused by flaky tests and race conditions rather than actual product defects.

When trunk breaks, every active lane in the fleet suffers. Pushing new changes onto a red trunk blinds developers and amplifies failures. The project owner made the call to pause all feature work and exploratory refactoring until continuous integration was stable and fast. It meant trading a slower morning for dramatically faster and more reliable days ahead.

We focused on the real bottlenecks. First, moving the test jobs to GitHub's hosted runners cut full run times from roughly 50 minutes down to 30.4 minutes median (n=12), virtually eliminating runner queue delays from 19 minutes to under 0.1 minutes. Second, the gate was updated to test only the parts a push touches, anchored to each job's last green run rather than rerunning everything blindly. Third, running cheap local gates before pushing caught simple defects in seconds. Following the runner switch, targeted refactoring rounds (r8 to r14) shaved minutes off the slowest tests, such as bringing a mobile browser suite down from 164 seconds to 63 seconds (n=3). We also changed how we view failures: counting errors per job rather than per run revealed that 42 red runs often stemmed from just six root causes.

This experience reinforced several core continuous integration best practices:
1. Measure first: time the actual waiting and count operations before proposing optimizations.
2. Prove every speed-up with a counting test and a control that fails on the old behaviour.
3. Run cheap checks locally before pushing so trunk remains clean.
4. Keep intentional test failures and controls on throwaway branches, never on master.
5. Treat test flakes as genuine defects with immediate priority.
6. Refactor continuously in small, measured rounds with stated sample sizes.
7. Assign every broken job to a single owning lane immediately.

Fixing continuous integration directly accelerates future product delivery. Shorter feedback loops and reliable green builds mean features ship with velocity and confidence.
