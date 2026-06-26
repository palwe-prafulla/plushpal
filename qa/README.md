# PlushBuddy QA

This folder holds product-level QA automation. Generated test-result artifacts
are written outside the repository under `~/Downloads/PlushPal/test-results` by
default.

## Layout

```text
qa/
  automation/   Device, simulator, browser, and MacStation E2E/smoke scripts
  unit/         Index of unit-test suites that live near their source code
```

Unit tests stay near the source they validate. Product and cross-surface automation lives here so release checks are easy to find.
