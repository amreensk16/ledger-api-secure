# RBAC personas

Three namespace-scoped personas for the `payments` namespace, bound to
Groups rather than named Users so this works without a real identity
provider - demo access via `kubectl --as=<user> --as-group=<group>`
impersonation (requires `impersonate` permission on the caller, which the
kind admin kubeconfig has by default).

| Persona    | Group                  | Role                | Can do                                              | Cannot do                                  |
|------------|------------------------|---------------------|------------------------------------------------------|---------------------------------------------|
| developer  | `payments:developers`  | `payments-developer`| read pods/services/configmaps/deployments, read logs | write anything, read Secrets                |
| operator   | `payments:operators`   | `payments-operator` | developer rights + update/scale deployments, exec    | read Secrets, edit RBAC                     |
| admin      | `payments:admins`      | built-in `admin` (namespace-scoped RoleBinding) | manage everything inside `payments`, incl. Secrets and RBAC | anything outside `payments` (not cluster-admin) |

## Demo

```bash
kubectl auth can-i update deployments --as=jane --as-group=payments:developers -n payments   # no
kubectl auth can-i get pods           --as=jane --as-group=payments:developers -n payments   # yes
kubectl auth can-i update deployments --as=sam  --as-group=payments:operators  -n payments   # yes
kubectl auth can-i get secrets        --as=sam  --as-group=payments:operators  -n payments   # no
kubectl auth can-i get secrets        --as=alex --as-group=payments:admins     -n payments   # yes
kubectl auth can-i delete namespaces  --as=alex --as-group=payments:admins     -n payments   # no (namespace-scoped, not cluster-admin)
```
