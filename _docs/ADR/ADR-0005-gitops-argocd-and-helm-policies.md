# ADR-0005: Впровадження GitOps на базі ArgoCD (App-of-Apps) та повна параметризація політик Kyverno у Helm

* **Status:** Accepted
* **Date:** 2026-10-21
* **Authors:** Alex.Viki

## Context
У рамках **Module 03 – Platform Engineering** поставлено два ключових завдання:
1. Налаштувати GitOps-систему для автоматичної доставки та синхронізації всіх майбутніх змін у кластері (обрано **ArgoCD**).
2. Переписати політики Kyverno з попереднього модуля на повноцінне використання параметризованого **Helm-чарту**, щоб уникнути хардкоду параметрів політик у шаблонах.

## Options Considered
1. **Option A: ArgoCD з патерном App-of-Apps + єдиний параметризований Helm-чарт (`lab-tenants`)**
   * *Pros:*
     - Візуальний UI та CLI, підтримка Sync Waves (`argocd.argoproj.io/sync-wave`), що дозволяє гарантувати встановлення Kyverno (Wave `1`) перед застосуванням `ClusterPolicy` (Wave `2`).
     - Патерн App-of-Apps (`platform-root`) автоматично підхоплює нові компоненти, додані в папку `module-03/argocd/apps/`.
     - Єдиний Helm-чарт `lab-tenants` централізує управління неймспейсами, базовим RBAC та всіма параметрами політик Kyverno (`failureAction`, `excludeNamespaces`, `rules`, `labelKey` тощо) через `values.yaml`.
   * *Cons:* Потребує налаштування `ignoreDifferences` та `ServerSideApply=true` для коректної роботи з великими CRD та вебхуками Kyverno, які модифікуються контролерами в рантаймі.
2. **Option B: FluxCD**
   * *Pros:* Легковаговий CLI-орієнтований GitOps оператор.
   * *Cons:* Відсутність офіційного повнофункціонального вбудованого Web UI з коробки порівняно з ArgoCD.
3. **Option C: Окремі розрізнені Helm-чарти для кожної політики**
   * *Pros:* Гранулярне версіонування кожної окремої політики.
   * *Cons:* Ускладнює підтримку тісно пов'язаних ресурсів (неймспейси, ролі `lab-namespace-rw` та політика `generate-tenant-rbac`, яка посилається на ці ролі).

## Decision
Ми вирішили використати **Option A**:
- Розгорнули **ArgoCD** у неймспейс `argocd` з методом відстеження ресурсів через анотації (`application.resourceTrackingMethod: annotation`).
- Налаштували кореневий додаток `platform-root` (App-of-Apps), який керує двома дочірніми додатками:
  1. `kyverno` (Sync Wave `1`) — підтримує актуальний стан Helm-релізу Kyverno з увімкненим `ServerSideApply=true`.
  2. `lab-tenants` (Sync Wave `2`) — синхронізує наш єдиний параметризований чарт `module-03/charts/lab-tenants`.
- Переписали всі шаблони політик Kyverno з використанням `_helpers.tpl` та гнучкої структури `values.yaml`.

## Rationale
- **Sync Waves (`1` -> `2`) + `SkipDryRunOnMissingResource=true`:** при розгортанні на «чистому» кластері CRD `ClusterPolicy` створюються під час інсталяції Kyverno на хвилі `1`, після чого на хвилі `2` розгортається `lab-tenants`.
- **Повна параметризація політик через Helm:** тепер зміна режиму політики `require-ro-rootfs` з `Audit` на `Enforce`, зміна списку виключених системних неймспейсів (`excludeNamespaces: [kube-system, kyverno, argocd]`) або додавання нової ролі для мутації лейбла `person` виконується виключно зміною значень у `values.yaml` без редагування шаблонів у `templates/`.
- **Ігнорування мутацій контролерів (`ignoreDifferences`):** Kyverno автоматично додає `caBundle` у свої `MutatingWebhookConfiguration`/`ValidatingWebhookConfiguration` та оновлює статус/виключення у `ClusterPolicy`. Конфігурація `ignoreDifferences` в ArgoCD запобігає хибному статусу `OutOfSync`.

## Consequences
* **Positive:**
  - Будь-які майбутні зміни (додавання `student04`, зміна параметрів політик або додавання нових інфраструктурних сервісів у `module-03/argocd/apps/`) автоматично застосовуються в кластері після `git push` завдяки `automated` sync (`prune: true`, `selfHeal: true`).
  - Політики Kyverno проходять валідацію `helm lint` та легко тестуються через `helm template --set ...`.
* **Negative / Risks:**
  - Для того, щоб ArgoCD міг синхронізувати локальні зміни у `module-03/`, вони мають бути запушені у віддалений репозиторій GitHub (`origin`).
