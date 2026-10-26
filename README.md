# Merck e-commerce on EKS (platform engineer simulation)

A small, working shop (frontend + REST backend) with everything needed to run it on Amazon EKS: container images, Kubernetes manifests, a reusable Terraform module, a CI/CD pipeline and a design document.

New to all of this? Read [docs/beginners-guide.md](docs/beginners-guide.md) first: it explains every concept and every file in plain language. The architecture, the Snowflake data flow, the secure ML call and the Entra ID sign-in are in [docs/design.md](docs/design.md).

## What is where

| Deliverable | Location |
| --- | --- |
| 1. Backend (FastAPI), unit tests, Dockerfile | [src/backend](src/backend) |
| 1. Frontend (single page), Dockerfile (nginx) | [frontend](frontend) |
| 2. Kubernetes manifests (Deployment, Service, Ingress, HPA, ConfigMap, Secret) | [k8s](k8s) |
| 3. Reusable Terraform module and the root that uses it | [infra/terraform](infra/terraform) |
| 4. Design and workflow | [docs/design.md](docs/design.md) |
| Architecture diagram (draw.io, AWS icons) | [docs/architecture.drawio](docs/architecture.drawio) |
| Working session plan (phases 1 to 5) | [docs/working-session.md](docs/working-session.md) |
| CI/CD pipeline | [.github/workflows/ci-cd.yml](.github/workflows/ci-cd.yml) |
| Run both containers on your laptop | [docker-compose.yml](docker-compose.yml) |

## The API

All cart calls need the header `X-Session-Id` (the UI generates one and keeps it in the browser).

| Method and path | Purpose |
| --- | --- |
| `GET /products` | List the catalog |
| `GET /products/{id}` | One product |
| `POST /cart/items` | Add to cart, body `{"product_id": 1, "quantity": 2}` |
| `PATCH /cart/items/{id}` | Set the quantity of a cart line, body `{"quantity": 3}` (1 to 99) |
| `DELETE /cart/items/{id}` | Remove a cart line |
| `GET /cart` | View the cart |
| `POST /cart/checkout` | Place the order. Optional header `Idempotency-Key`: repeating a request with the same key returns the original order instead of a new one |
| `GET /healthz` | Liveness and readiness probe |

Interactive API docs are at `http://localhost:8000/docs` when you run it locally (switched off in the cluster).

## Run it

Commands are for PowerShell on Windows, from this folder.

**1. Backend only, with tests** (needs Python 3.12 or newer)

```powershell
cd src\backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements-dev.txt
pytest -q
uvicorn app:merck_group_app --reload --port 8000
```

**1b. Backend and frontend page without Docker** (two terminals; the page calls `/api/...`, so a plain file server is not enough and `scripts/dev_server.py` plays the role of nginx)

```powershell
# terminal 1: backend
cd src\backend
uvicorn app:merck_group_app --port 8000

# terminal 2: frontend page plus the /api proxy
python scripts\dev_server.py
```

Open <http://localhost:8080>. Settings: `$env:PORT` (default 8080) and `$env:BACKEND_URL` (default `http://127.0.0.1:8000`).

**2. Whole shop in containers** (needs Docker Desktop running)

```powershell
docker compose up --build
```

Open <http://localhost:8080>. Stop with `Ctrl+C`, then `docker compose down`.

**3. On a local Kubernetes** (Docker Desktop with Kubernetes enabled, or kind/minikube)

```powershell
docker build -t merck-shop-backend:local src/backend
docker build -t merck-shop-frontend:local frontend
kubectl apply -k k8s/overlays/local
kubectl -n merck-shop get pods
kubectl -n merck-shop port-forward svc/frontend 8080:80
```

Open <http://localhost:8080>. Remove everything with `kubectl delete -k k8s/overlays/local`.

With **minikube** the cluster cannot see images built by your host Docker. Run `minikube start` first, then build the images inside minikube instead of the two `docker build` lines:

```powershell
minikube image build -t merck-shop-backend:local src/backend
minikube image build -t merck-shop-frontend:local frontend
```

## Deploy to EKS

Prerequisites in the cluster: AWS Load Balancer Controller, metrics-server (for the autoscalers) and External Secrets Operator. Put the backend password in AWS Secrets Manager as secret `merck-shop/dev/backend` with the JSON key `db_password`.

There are two equivalent ways to create the Kubernetes objects. **Use one of them per cluster, not both.**

**A. Terraform (the module in [infra/terraform](infra/terraform))**: creates the namespace, ECR repositories, log groups, the IAM role for the backend, and all Kubernetes objects.

```powershell
cd infra\terraform
copy terraform.tfvars.example terraform.tfvars   # edit cluster_name and the image tags
terraform init
terraform apply                                  # first run creates ECR; pods wait for images
```

Then push the images to the ECR repositories printed in the `ecr_repository_urls` output (CI does this on every merge), and apply again with the new tags.

**B. Plain manifests with kustomize**: edit the `<ACCOUNT_ID>`, `<REGION>` and tag placeholders in [k8s/overlays/aws/kustomization.yaml](k8s/overlays/aws/kustomization.yaml), then:

```powershell
kubectl apply -k k8s/overlays/aws
```

## Status of this exercise

Checked here: the 14 backend unit tests pass, the API answers correctly over HTTP, all three kustomize overlays render, and `terraform validate` and `terraform fmt` pass.

Not checked here: building the Docker images (the Docker daemon was not running) and applying to a real EKS cluster, so the first run on a cluster may need small adjustments (names, ALB annotations, add-ons).

Known limit by design: the data layer is in memory, so each backend pod keeps its own carts. The demo autoscaler therefore starts at one replica. See section 8 of the design document for the Aurora path.
