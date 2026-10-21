# Module 02 – Security & Policy as Code

## Архітектура рішення (Helm + Kyverno Policy as Code)

Для масштабування кількості студентів (`student04`, `student05`, `student06`...) без дублювання YAML-файлів реалізовано комбінацію **Helm Chart (`charts/lab-tenants`)** та **Kyverno (`Generate`, `Validate`, `Mutate` policies)**:

1. **Helm Chart (`charts/lab-tenants`)**:
   - Зберігає список студентів у `values.yaml` та створює відповідні неймспейси з лейблами `role=student` або `role=mentor`.
   - Створює базові ролі `ClusterRole` (`lab-namespace-rw`, `lab-namespace-ro`) без прав `Cluster Admin`.
   - Створює кастомні додаткові `RoleBinding` зі списку `extraReadOnlyNamespaces` (наприклад, RO-доступ для `student02` у `student01` та `default`).
2. **Kyverno Generate Policy (`generate-tenant-rbac`)**:
   - Автоматично реагує на появу будь-якого неймспейсу з лейблом `role=student` або `role=mentor`.
   - Генерує `ServiceAccount`, `Secret` (`kubernetes.io/service-account-token`), RW `RoleBinding` для власника неймспейсу та RW `RoleBinding` для `mentor` у кожному студентському неймспейсі.
3. **Kyverno Validate Policy (`require-ro-rootfs`)**:
   - Перевіряє наявність `securityContext.readOnlyRootFilesystem: true` у контейнерах подів у режимі **Audit** (`failureAction: Audit`) та формує звіти `PolicyReport`.
4. **Kyverno Mutate Policy (`add-person-label`)**:
   - Автоматично додає лейбл `person: student` до подів у неймспейсах з `role=student` та `person: mentor` у неймспейсі з `role=mentor`. Усі інші неймспейси (наприклад, `default`) цього лейбла не отримують.

---

## Як додати нового студента (наприклад, `student04`)

### Варіант А — Через Helm (`values.yaml`)
Додайте рядок у `charts/lab-tenants/values.yaml`:
```yaml
students:
  - name: student01
  - name: student02
    extraReadOnlyNamespaces:
      - student01
      - default
  - name: student03
  - name: student04
```
Оновіть реліз та згенеруйте kubeconfig:
```bash
helm upgrade --install lab-tenants ~/KubernetesInProduction/module-02/charts/lab-tenants -n default
~/KubernetesInProduction/module-02/generate-kubeconfigs.sh
```

### Варіант Б — Навіть без Helm (чистий Kyverno Generate)
Достатньо створити неймспейс з лейблом `role=student` — Kyverno сам створить `ServiceAccount`, токен і всі `RoleBinding` для студента та ментора:
```bash
kubectl create ns student04
kubectl label ns student04 role=student student=student04
~/KubernetesInProduction/module-02/generate-kubeconfigs.sh
```

---

## Матриця доступів RBAC
| Користувач | `mentor` | `student01` | `student02` | `student03` | `default` | Cluster Admin |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **mentor** | RW | RW | RW | RW | — | Ні |
| **student01** | — | RW | — | — | — | Ні |
| **student02** | — | RO | RW | — | RO | Ні |
| **student03** | — | — | — | RW | — | Ні |

---

## Перевірка та тестування
```bash
cd ~/KubernetesInProduction/module-02
./generate-kubeconfigs.sh   # Динамічно генерує kubeconfigs/*.kubeconfig для всіх role in (mentor,student)
./verify-rbac.sh            # Перевіряє RBAC права (67/67 тестів)
./verify-kyverno.sh         # Перевіряє Kyverno Mutate, Validate (Audit) та Generate політики (9/9 тестів)
```

---

## Architecture Decision Records (ADR)
Усі архітектурні рішення та обґрунтування вибору технологій задокументовані у папці `_docs/ADR/`:
- [ADR-0001: Вибір k3s як дистрибутива Kubernetes для лабораторного кластера](../_docs/ADR/ADR-0001-kubernetes-cluster-k3s.md)
- [ADR-0002: Модель автентифікації (ServiceAccount Tokens) та матриця RBAC без прав Cluster Admin](../_docs/ADR/ADR-0002-rbac-and-authentication-model.md)
- [ADR-0003: Масштабування тенантів за допомогою Helm Chart та Kyverno Generate Policy](../_docs/ADR/ADR-0003-tenant-automation-helm-and-kyverno-generate.md)
- [ADR-0004: Впровадження політик валідації (Read-Only RootFS в режимі Audit) та мутації подів (лейбл person) через Kyverno](../_docs/ADR/ADR-0004-kyverno-pod-validation-and-mutation-policies.md)
