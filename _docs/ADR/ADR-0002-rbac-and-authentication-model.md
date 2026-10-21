# ADR-0002: Модель автентифікації (ServiceAccount Tokens) та матриця RBAC без прав Cluster Admin

* **Status:** Accepted
* **Date:** 2026-10-19
* **Authors:** Alex.Viki

## Context
У кластері необхідно реалізувати Multi-Tenancy ізоляцію для навчального середовища з чіткими вимогами безпеки:
1. Окремий неймспейс для ментора (`mentor`) та 3 неймспейси для студентів (`student01`, `student02`, `student03`).
2. Кожен учасник (ментор і кожен студент) повинен мати власний ізольований `kubeconfig` файл.
3. Розмежування прав доступу (RBAC):
   - **Ментор** має RW-доступ до свого неймспейсу (`mentor`) та до всіх неймспейсів студентів (`student01`, `student02`, `student03`).
   - **Студенти 01 та 03** мають RW-доступ виключно до власних неймспейсів (`student01` та `student03` відповідно).
   - **Студент 02** має RW-доступ до власного неймспейсу (`student02`) та RO (Read-Only) доступ до неймспейсів `student01` і `default`.
   - **Жоден користувач** (ані ментор, ані студенти) не повинен мати прав `Cluster Admin` або можливості підвищити свої привілеї (Privilege Escalation).

## Options Considered
1. **Option A: ServiceAccounts + Secrets (`kubernetes.io/service-account-token`) + шаблони `ClusterRole`, прив'язані через `RoleBinding`**
   * *Pros:* Повністю нативні ресурси Kubernetes, якими можна керувати декларативно через Helm або генерувати автоматично через Kyverno; токени автоматично підписуються контролером Kubernetes і легко експортуються у `kubeconfig`. Використання двох загальних `ClusterRole` (`lab-namespace-rw` та `lab-namespace-ro`), прив'язаних через `RoleBinding` у конкретних неймспейсах, унеможливлює доступ на рівні кластера.
   * *Cons:* Довгоживучі токени у Secret вимагають надійного зберігання згенерованих `.kubeconfig` файлів (виключення з Git через `.gitignore`).
2. **Option B: X.509 клієнтські сертифікати через `CertificateSigningRequest` (CSR API)**
   * *Pros:* Не потребує створення `ServiceAccount` у кластері; класичний підхід для зовнішніх користувачів.
   * *Cons:* Складний процес автоматизації (генерація приватних ключів OpenSSL, створення CSR, ручний або скриптовий `kubectl certificate approve`); неможливо повністю автоматизувати засобами Kyverno `generate` без зовнішніх скриптів; відкликання сертифікатів у Kubernetes є складним.
3. **Option C: Окремі `Role` у кожному неймспейсі замість спільних `ClusterRole`**
   * *Pros:* Повна локалізація правил у межах неймспейсу.
   * *Cons:* Дублювання однакових списків `apiGroups`/`resources`/`verbs` у кожному неймспейсі; при зміні переліку дозволених ресурсів доведеться оновлювати десятки об'єктів `Role`.

## Decision
Ми обрали **Option A**:
- Автентифікація кожного учасника здійснюється через окремий `ServiceAccount` у його домашньому неймспейсі та прив'язаний `Secret` типу `kubernetes.io/service-account-token`, на базі якого формується індивідуальний файл `kubeconfigs/<user>.kubeconfig`.
- Авторизація побудована на двох шаблонах `ClusterRole` (`lab-namespace-rw` та `lab-namespace-ro`), які прив'язуються виключно через неймспейсні `RoleBinding` (без жодного `ClusterRoleBinding`).

## Rationale
- Прив'язка `ClusterRole` через **namespaced `RoleBinding`** — це рекомендований патерн Kubernetes: ми визначаємо шаблон прав («RW в неймспейсі» та «RO в неймспейсі») лише один раз, але обмежуємо область його дії конкретним неймспейсом, де створено `RoleBinding`.
- Відсутність прав на ресурси `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings`, `namespaces`, `nodes` у правилах `lab-namespace-rw` гарантує, що ні ментор, ні студенти не мають прав `Cluster Admin` і не можуть самостійно змінити свої RBAC-політики.
- У ролі `lab-namespace-ro` додатково виключено доступ до `secrets` та `pods/exec`, щоб студент із RO-доступом (`student02` у `student01` та `default`) не міг викрасти чутливі дані або виконати команди всередині чужих контейнерів.

## Consequences
* **Positive:**
  - Чітка і прозора матриця доступів (підтверджена 67 автоматичними тестами у `verify-rbac.sh`).
  - Спільні ролі `lab-namespace-rw` та `lab-namespace-ro` легко підтримувати в одному місці.
  - Повна сумісність із динамічною генерацією ресурсів через Kyverno.
* **Negative / Risks:**
  - Файли `*.kubeconfig` містять bearer-токени у відкритому вигляді, тому директорія `kubeconfigs/*.kubeconfig` обов'язково додана до `.gitignore` і має права доступу `0600`.
