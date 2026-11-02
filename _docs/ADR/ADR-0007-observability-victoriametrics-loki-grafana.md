# ADR-0007: Впровадження стеку Observability (VictoriaMetrics + Grafana Loki + Promtail + Grafana) та декларативних дашбордів і алярмів

* **Status:** Accepted
* **Date:** 2026-11-02
* **Authors:** Alex.Viki

## Context
У межах **Module 05 – Observability & Troubleshooting** необхідно реалізувати повноцінну систему спостережуваності (Observability) для нашого Multi-Tenant кластера з такими вимогами:
1. Встановити систему моніторингу та збору логів у кластер.
2. Створити дашборд для відстеження навантаження на ноди кластера в розрізі студентських неймспейсів (`student01`, `student02`, `student03` тощо).
3. Створити дашборд та налаштувати алярм (Alert), який спрацьовує при знаходженні в логах подів сповіщення про непроходження аудиту за політикою `readonly root filesystem` (`require-ro-rootfs`).

Ключове технічне обмеження: віртуальна машина кластера має **3.8 GiB RAM**, де вже працюють `k3s`, `ArgoCD`, `Kyverno` та `Istio`. Тому обраний стек моніторингу та логування повинен мати мінімальний footprint по оперативній пам'яті, підтримувати PromQL/LogQL та керуватися декларативно через GitOps (ArgoCD).

## Options Considered
1. **Option A: VictoriaMetrics (`victoria-metrics-k8s-stack`) + Grafana Loki (`loki-stack`: Loki + Promtail) + Grafana Sidecar Provisioning**
   * *Pros:*
     - `vmsingle` та `vmagent` використовують у 3–4 рази менше оперативної пам'яті (~150–200 MiB), ніж класичний сервер Prometheus, при повній сумісності з PromQL та дашбордами Grafana.
     - `Loki` у режимі SingleBinary + `Promtail` легко збирають логи всіх подів кластера з мінімальним споживанням ресурсів (~100 MiB RAM).
     - Вбудовані у Grafana sidecar-контейнери (`grafana-sc-dashboard`, `grafana-sc-alerts`, `grafana-sc-datasources`) дозволяють зберігати дашборди та правила алертингу як звичайні `ConfigMap` у Git-репозиторії (Dashboards-as-Code та Alerts-as-Code).
   * *Cons:* Потребує вимкнення дублюючого рендерингу великих CRD (`skipCrds: true`, `crds.plain: false`) після первинної інсталяції, щоб не перевантажувати API-сервер k3s під час частих синхронізацій ArgoCD.
2. **Option B: Класичний `kube-prometheus-stack` (Prometheus + Alertmanager + Grafana) + Loki**
   * *Pros:* Найбільш відомий стандартний чарт спільноти Prometheus.
   * *Cons:* Високе базове споживання RAM сервером Prometheus (~500–800 MiB), що на VM із 3.8 GiB RAM призводить до активного використання swap та ризику `OOMKilled`.
3. **Option C: ELK / OpenSearch Stack (Elasticsearch + FluentBit + Kibana)**
   * *Pros:* Потужний повнотекстовий пошук.
   * *Cons:* Потребує щонайменше 2–4 GiB RAM тільки для одного вузла JVM Elasticsearch/OpenSearch, що є неприйнятним для нашої інфраструктури.

## Decision
Ми вирішили використати **Option A: VictoriaMetrics (`victoria-metrics-k8s-stack`) + Grafana Loki (`loki-stack`) + Grafana**, розгорнуті в неймспейсі `monitoring` через ArgoCD GitOps (`module-03/argocd/apps/vm-k8s-stack.yaml` та `loki-stack.yaml`), а кастомні дашборди та алярми виділити в окремий Helm-чарт `module-05/charts/observability` (додаток ArgoCD `observability-config`).

## Rationale
1. **Ефективність ресурсів:** Усі 10 подів стеку в неймспейсі `monitoring` (`vmsingle`, `vmagent`, `vmalert`, `vmalertmanager`, `grafana`, `kube-state-metrics`, `node-exporter`, `victoria-metrics-operator`, `loki-0`, `promtail`) стабільно працюють у межах ~350–400 MiB RAM.
2. **Налаштування логування Kyverno для аудиту (`verbosity: 3`):**
   - За замовчуванням (`--v=2`) `kyverno-admission-controller` не виводить у stdout деталі непроходження правил у режимі `Audit`.
   - Підняття рівня логування до `features.logging.verbosity: 3` у `kyverno.yaml` забезпечує запис у stdout структурованого повідомлення:
     `validation error ... logger=engine.validate new.kind=Pod new.name=<pod> new.namespace=<ns> path=/spec/containers/0/securityContext/ policy.name=require-ro-rootfs rule.name=validate-readOnlyRootFilesystem`.
   - Додатково в політиці `require-ro-rootfs` вимкнено `checkInitContainers: false`, щоб службовий контейнер `istio-init` (який потребує root-прав для налаштування `iptables`) не викликав хибних спрацьовувань на валідних подах студентів.
3. **Dashboards-as-Code та Alerts-as-Code:**
   - Дашборд `student-namespaces-node-load` автоматично обчислює частку CPU/RAM ноди та графіки споживання ресурсів за динамічним фільтром `namespace=~"student.*"`.
   - Дашборд `kyverno-ro-rootfs-audit-logs` та правило Grafana Unified Alerting `ro-rootfs-audit-log-alert` використовують LogQL-запит до Loki і миттєво переходять у стан `Firing` при появі в логах сповіщення про непроходження аудиту `require-ro-rootfs`.

## Consequences
* **Positive:**
  - Повна прозорість споживання ресурсів ноди кожним студентом (`student01`, `student02`, `student03` і будь-якими майбутніми `studentXX`).
  - Автоматичне виявлення та алертинг по логах при запуску подів без `readOnlyRootFilesystem: true`.
  - Усі 8 додатків ArgoCD (`platform-root`, `kyverno`, `lab-tenants`, `istio-base`, `istiod`, `vm-k8s-stack`, `loki-stack`, `observability-config`) синхронізуються автоматично з Git і мають статус `Synced` / `Healthy`.
* **Negative / Risks:**
  - Оскільки в навчальному середовищі використовується `vmsingle` та `loki` з `retentionPeriod: 1d` без зовнішнього S3-сховища, історичні метрики та логи зберігаються локально протягом 24 годин.
