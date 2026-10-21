# ADR-0004: Впровадження політик валідації (Read-Only RootFS в режимі Audit) та мутації подів (лейбл person) через Kyverno

* **Status:** Accepted
* **Date:** 2026-10-19
* **Authors:** Alex.Viki

## Context
У межах модуля **Security & Policy as Code** необхідно було реалізувати дві політики безпеки та управління метаданими для робочих навантажень (Pods):
1. **Валідація безпеки контейнерів:** перевіряти, що коренева файлова система контейнерів налаштована в режимі тільки для читання (`securityContext.readOnlyRootFilesystem: true`), але в **режимі аудиту (Audit)**, щоб не блокувати роботу існуючих або навчальних деплойментів.
2. **Автоматична класифікація (мутація) подів:** автоматично додавати лейбл `person` у всі поди, що створюються:
   - у студентських неймспейсах — `person: student`;
   - у неймспейсі ментора — `person: mentor`;
   - в усіх інших неймспейсах (`default`, `kube-system`, `kyverno` тощо) цей лейбл **не повинен** додаватися взагалі.

## Options Considered
1. **Option A: Kyverno (`ClusterPolicy` з правилами `validate` та `mutate`)**
   * *Pros:* Політики пишуться декларативно стандартним YAML без необхідності вивчати окрему мову програмування; підтримує як `validate` (у режимах `Audit` та `Enforce` із автоматичним формуванням стандартних `PolicyReport`), так і `mutate` (`patchStrategicMerge`), а також `generate` (використаний в ADR-0003); підтримує `namespaceSelector` для точного таргетування за лейблами неймспейсів.
   * *Cons:* Додає 4 контролери у неймспейс `kyverno` (admission, background, cleanup, reports).
2. **Option B: OPA Gatekeeper**
   * *Pros:* Потужний рушій на основі мови Rego, широке поширення в індустрії.
   * *Cons:* Вимагає написання `ConstraintTemplate` на мові Rego та окремих CRD для кожного правила; набагато складніша конфігурація для мутації ресурсів (`AssignMetadata`) і відсутність повноцінного аналога `generate` правил з коробки.
3. **Option C: Вбудовані Kubernetes `ValidatingAdmissionPolicy` та `MutatingAdmissionPolicy` (CEL)**
   * *Pros:* Вбудовані безпосередньо в API-сервер Kubernetes, не потребують зовнішніх вебхуків.
   * *Cons:* Не покривають генерацію ресурсів (RBAC/Secrets з ADR-0003) та не створюють зручних CR-звітів `PolicyReport` без додаткових компонентів.

## Decision
Ми обрали **Option A: Kyverno** та реалізували дві політики у складі Helm-чарту `lab-tenants`:
1. `require-ro-rootfs` (`templates/kyverno-validate-ro-rootfs.yaml`) — `ClusterPolicy` з `failureAction: Audit` та `background: true`.
2. `add-person-label` (`templates/kyverno-mutate-person-label.yaml`) — `ClusterPolicy` з двома правилами мутації, які використовують `namespaceSelector` за лейблами `role: student` та `role: mentor`.

## Rationale
- **Використання `namespaceSelector` замість переліку імен неймспейсів:** у політиці `add-person-label` замість хардкоду `namespaces: ["student01", "student02", "student03"]` ми використали вибірку `namespaceSelector.matchLabels.role: student` та `role: mentor`. Завдяки цьому:
  - при додаванні `student04`, `student05` тощо політика мутації автоматично працює для них без жодних змін у коді політики;
  - системні та інші неймспейси (`default`, `kube-system`, `kyverno`), які не мають лейбла `role`, гарантовано ігноруються політикою і не отримують лейбл `person`.
- **Режим `failureAction: Audit` + `background: true` у політиці `require-ro-rootfs`:** дозволяє перевіряти як нові поди під час Admission, так і вже існуючі поди у фоновому режимі, записуючи результати (`pass` / `fail`) у стандартні об'єкти `PolicyReport` у відповідному неймспейсі без зупинки навчального процесу студентів.

## Consequences
* **Positive:**
  - Всі поди студентів та ментора автоматично маркуються лейблом `person=student` або `person=mentor`, що дозволяє використовувати цей лейбл для селекторів у `NetworkPolicy`, моніторингу (Prometheus) або підрахунку вартості/квот.
  - Адміністратор та ментор можуть у будь-який момент переглянути стан дотримання вимог `readOnlyRootFilesystem` командою `kubectl get policyreport -A`, не блокуючи роботу студентів.
  - Поведінка обох політик автоматично верифікується скриптом `module-02/verify-kyverno.sh`.
* **Negative / Risks:**
  - Оскільки `require-ro-rootfs` працює в режимі `Audit`, небезпечні поди все одно запускаються; у майбутньому при переході до Production для критичних неймспейсів режим може бути змінений на `Enforce`.
  - У версії Kyverno 1.19 з'явилось попередження про поступову міграцію з `kyverno.io/v1 ClusterPolicy` на нові типи `policies.kyverno.io` (CEL-based), що варто врахувати при оновленні Kyverno у наступних релізах.
