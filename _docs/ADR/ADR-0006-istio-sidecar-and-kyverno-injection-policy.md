# ADR-0006: Розгортання Istio Service Mesh у режимі Sidecar та інжекція istio-proxy через Kyverno Mutate Policy

* **Status:** Accepted
* **Date:** 2026-10-22
* **Authors:** Alex.Viki

## Context
У межах **Module 04 – Service Mesh** необхідно виконати дві вимоги:
1. Встановити **Istio Service Mesh** у кластер у класичному режимі **sidecar**.
2. Створити політику **Kyverno**, завдяки якій усі поди з лейблом `person: student` автоматично запускатимуться з `istio-sidecar` (`istio-proxy`) контейнером, тоді як інші поди (наприклад, ментора `person: mentor` або системні) залишаться без sidecar-проксі.

Також необхідно забезпечити коректну взаємодію між двома мутуючими вебхуками в Kubernetes: **Kyverno MutatingWebhook** (який динамічно додає лейбл `person: student` на поди в студентських неймспейсах під час Admission) та **Istio Sidecar Injector MutatingWebhook** (який інжектить контейнер `istio-proxy`).

## Options Considered
1. **Option A: Встановлення Istio через офіційні Helm-чарти (`istio/base` + `istio/istiod`) під управлінням ArgoCD + Kyverno Mutate Policy (`sidecar.istio.io/inject: "true"`) + `reinvocationPolicy: IfNeeded`**
   * *Pros:*
     - Повністю декларативний GitOps-підхід: Istio керується через ArgoCD Applications (`istio-base` на Sync Wave `0`, `istiod` на Sync Wave `1`).
     - Kyverno-політика `inject-istio-sidecar-for-students` не хардкодить всередині себе громіздку специфікацію контейнера Envoy (`istio-proxy`), а додає стандартний керуючий лейбл Istio `sidecar.istio.io/inject: "true"` на всі поди, що мають `person: student`.
     - Встановлення `sidecarInjectorWebhook.reinvocationPolicy: IfNeeded` у конфігурації `istiod` вирішує проблему порядку виконання мутуючих вебхуків Kubernetes: навіть якщо вебхук Istio спрацював першим (коли под ще не мав лейблів від Kyverno), після мутації від Kyverno API-сервер повторно викличе вебхук Istio, який успішно згенерує та додасть `istio-init` і `istio-proxy`.
   * *Cons:* Вимагає розуміння механізму `reinvocationPolicy` у Kubernetes Dynamic Admission Control.
2. **Option B: Пряма мутація `spec.containers` (додавання `istio-proxy` контейнера безпосередньо в YAML політики Kyverno)**
   * *Pros:* Не залежить від лейблів інжекції Istio.
   * *Cons:* Антипатерн для Istio у Production: Envoy-контейнер у Istio потребує десятків специфічних аргументів, змінних середовища, `istio-init` контейнера для налаштування `iptables`, монтування сертифікатів (`istio-envoy`, `istio-token`, `istiod-ca-cert`) та prober-rewrite, які генеруються динамічно шаблоном `istiod` залежно від версії меша. Ручне прописування контейнера в Kyverno призведе до непрацездатного sidecar-проксі.
3. **Option C: Встановлення Istio через імперативний `istioctl install` та додавання лейбла `istio-injection=enabled` на неймспейси**
   * *Pros:* Швидкий старт вручну.
   * *Cons:* Порушує GitOps-принципи з Module 03; крім того, інжекція на рівні неймспейсу орієнтується на неймспейс, а не на вимогу завдання — таргетувати саме поди з лейблом `person: student`.

## Decision
Ми обрали **Option A**:
1. Розгорнули Istio `v1.30.6` у режимі Sidecar через два ArgoCD додатки: `istio-base` та `istiod` (з `sidecarInjectorWebhook.reinvocationPolicy: IfNeeded`).
2. Додали до єдиного Helm-чарту `lab-tenants` (`v0.3.0`) нову параметризовану політику Kyverno `inject-istio-sidecar-for-students` (`templates/kyverno-mutate-istio-sidecar.yaml`), яка знаходить усі поди з `person: student` та додає їм лейбл `sidecar.istio.io/inject: "true"`.
3. Додали у чарт `lab-tenants` конфігурацію `MutatingWebhookConfiguration` з іменем `z-istio-sidecar-injector` (`templates/istio-post-kyverno-webhook.yaml`), яка гарантує виклик інжектора Istio **після** завершення двоступеневої мутації Kyverno.

## Rationale
- **Делегування генерації контейнера нативному інжектору `istiod`:** Kyverno виступає як Policy Decision Point (вирішує, *яким* подам потрібен sidecar на основі бізнес-лейбла `person: student`), а `istiod` виступає як механізм інжекції, що гарантує 100% валідну конфігурацію `istio-proxy` та `istio-init` (у Istio 1.30+ використовується сучасний Kubernetes Native Sidecar — `initContainer` з `restartPolicy: Always`).
- **Вирішення алфавітного порядку MutatingWebhooks у Kubernetes:**
  - Kubernetes API-сервер викликає `MutatingWebhookConfiguration` суворо в алфавітному порядку за іменем.
  - Стандартний вебхук `istio-sidecar-injector` (`i`) виконується **до** `kyverno-resource-mutating-webhook-cfg` (`k`). Крім того, Kubernetes обмежує `reinvocationPolicy: IfNeeded` максимум одним повторним викликом на кожен вебхук за час Admission. Коли под створюється у `student01` без лейблів, на першому проході Kyverno додає `person: student`, а на реінвокації додає `sidecar.istio.io/inject: "true"`, тому вебхук із префіксом `z-` (`z-istio-sidecar-injector`, де `"z" > "k"`) гарантовано бачить обидва згенеровані лейбли і виконує інжекцію `istio-proxy` за один запит `CREATE Pod`.
  - Контролер `istiod` (webhook patcher) автоматично підставляє актуальний `caBundle` у `z-istio-sidecar-injector` завдяки лейблу `istio.io/rev: "default"`.

## Consequences
* **Positive:**
  - Усі поди з `person: student` автоматично отримують повноцінний `istio-proxy` sidecar (перевірено у `module-04/verify-service-mesh.sh`).
  - Поди ментора (`person: mentor`) та системні поди не отримують sidecar-контейнерів і не витрачають зайві ресурси кластера.
  - Весь стек (ArgoCD + Kyverno + Istio + політики тенантів) повністю керується через GitOps.
* **Negative / Risks:**
  - Додано неймспейс `istio-system` до списку `excludeNamespaces` у політиці `require-ro-rootfs`, щоб службові компоненти Istio не створювали зайвого шуму у звітах аудиту тенантів.
