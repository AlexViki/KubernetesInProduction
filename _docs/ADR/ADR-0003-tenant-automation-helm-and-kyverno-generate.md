# ADR-0003: Масштабування тенантів за допомогою Helm Chart та Kyverno Generate Policy

* **Status:** Accepted (Supersedes статичні маніфести `01-namespaces.yaml` та `02-rbac.yaml`)
* **Date:** 2026-10-19
* **Authors:** Alex.Viki

## Context
На першому етапі неймспейси та RBAC для ментора і трьох студентів (`student01`..`student03`) були описані у статичних YAML-файлах (`01-namespaces.yaml` та `02-rbac.yaml`). Проте при появі нових студентів (`student04`, `student05`, `student06` тощо) ручне копіювання блоків YAML призводить до дублювання коду (понад 50 рядків на кожного нового студента: `Namespace`, `ServiceAccount`, `Secret`, `RoleBinding` для студента, `RoleBinding` для ментора) та високого ризику помилок конфігурації.

Потрібно було обрати підхід для автоматизації створення нових тенантів та їхніх облікових даних без ручного клонування YAML-файлів.

## Options Considered
1. **Option A: Статичні YAML-маніфести + Bash-шаблонізація**
   * *Pros:* Не потребує сторонніх інструментів.
   * *Cons:* Погано масштабується, важко підтримувати стан (видалення/оновлення студентів), не відповідає практикам Cloud Native та GitOps.
2. **Option B: Тільки Helm Chart (`lab-tenants`)**
   * *Pros:* Всі ресурси генеруються циклами `{{- range .Values.students }}` з єдиного файлу `values.yaml`.
   * *Cons:* Якщо неймспейс студента створюється поза межами цього Helm-чарту (наприклад, вручну або іншим процесом), він залишиться без налаштованого RBAC та доступу ментора.
3. **Option C: Комбінація Helm Chart + Kyverno Generate Policy (`generate-tenant-rbac`)**
   * *Pros:*
     - Helm керує списком студентів (`values.yaml`), базовими `ClusterRole`, самою політикою Kyverno та специфічними винятками (`extraReadOnlyNamespaces` для `student02`).
     - Kyverno на рівні кластера автоматично реагує на будь-який неймспейс із лейблом `role=student` або `role=mentor` і миттєво генерує в ньому `ServiceAccount`, `Secret` (токен), RW `RoleBinding` для студента та RW `RoleBinding` для ментора.
   * *Cons:* Вимагає надання додаткових RBAC-прав для `kyverno:background-controller` (право створювати `ServiceAccount`, `Secret`, `RoleBinding` та робити `bind` для `lab-namespace-rw`) і врахування життєвого циклу токенів Kubernetes.
4. **Option D: Terraform / OpenTofu**
   * *Pros:* Зручно генерувати локальні файли `kubeconfig` через `local_sensitive_file`.
   * *Cons:* Вимагає зберігання та синхронізації Terraform state-файлу поза кластером.

## Decision
Ми вирішили використати **Option C: Комбінацію Helm Chart (`module-02/charts/lab-tenants`) та Kyverno Generate Policy (`generate-tenant-rbac`)**. Статичні файли `01-namespaces.yaml` та `02-rbac.yaml` були замінені та видалені.

## Rationale
Цей підхід демонструє справжній **Policy as Code** у дії:
1. Щоб додати `student04`, достатньо додати один рядок `- name: student04` у `values.yaml` (або просто створити неймспейс із лейблом `role=student`).
2. Ми також вирішили важливий технічний нюанс роботи Kyverno з токенами Kubernetes:
   - Для `ServiceAccount` та `RoleBinding` увімкнено `synchronize: true`, щоб Kyverno захищав їх від випадкового видалення чи модифікації.
   - Правило генерації `Secret` (`kubernetes.io/service-account-token`) тригериться на створення `ServiceAccount` (з виключенням `default`) і має `synchronize: false`. Це необхідно тому, що при `synchronize: true` Kyverno перезаписував би поле `data` у Secret назад у порожній стан, стираючи `ca.crt` та `token`, які туди асинхронно записує вбудований Token Controller у Kubernetes.
3. Для роботи Kyverno з RBAC створено агреговану роль `kyverno:generate-tenant-rbac` з лейблами `rbac.kyverno.io/aggregate-to-background-controller: "true"` та `rbac.kyverno.io/aggregate-to-admission-controller: "true"`, обмежену правом `bind` виключно для ролей `lab-namespace-rw` та `lab-namespace-ro`.

## Consequences
* **Positive:**
  - Повна автоматизація онбордингу нових студентів (`student04`, `student05` тощо) без дублювання YAML.
  - Скрипт `generate-kubeconfigs.sh` більше не містить хардкоду імен студентів, а динамічно знаходить усі неймспейси за селектором `role in (mentor,student)`.
  - Гарантована консистентність RBAC: жоден студентський неймспейс не може залишитись без доступу ментора.
* **Negative / Risks:**
  - Залежність від працездатності `kyverno-background-controller` у кластері (якщо контролер зупинений, генерація RBAC для нових неймспейсів відкладеться до його відновлення).
