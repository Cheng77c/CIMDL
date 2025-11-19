#!/bin/bash

# ==============================================================================
# Cube Studio 一键启动脚本
# ==============================================================================
# 说明：此脚本会自动启动所有必需的 Docker Compose 和 Kubernetes 服务
# 作者：Claude Code
# 创建时间：2025-11-07
# ==============================================================================

set -e  # 遇到错误立即退出

# 获取脚本所在目录作为项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 打印标题
print_header() {
    echo ""
    echo "=============================================================================="
    echo "  🚀 Cube Studio 一键启动脚本"
    echo "=============================================================================="
    echo ""
}

# 检查依赖
check_dependencies() {
    log_info "检查系统依赖..."
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker 未安装，请先安装 Docker"
        exit 1
    fi
    
    # 检查 docker compose
    if ! docker compose version &> /dev/null; then
        log_error "Docker Compose 未安装或版本不兼容"
        exit 1
    fi
    
    # 检查 Kind
    if ! command -v kind &> /dev/null; then
        log_error "Kind 未安装，请先安装 Kind"
        exit 1
    fi
    
    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装，请先安装 kubectl"
        exit 1
    fi
    
    log_success "所有依赖检查通过"
}

# 清理旧进程
cleanup_old_processes() {
    log_info "清理旧进程..."

    # 停止现有的 Docker Compose
    if [ -f "$PROJECT_ROOT/install/docker/docker-compose.yml" ]; then
        cd "$PROJECT_ROOT/install/docker"
        docker compose down 2>/dev/null || true
    fi

    # 检查是否需要强制重建集群（通过环境变量控制）
    if [ "$FORCE_REBUILD_CLUSTER" = "true" ]; then
        # 删除现有的 Kind 集群
        if kind get clusters 2>/dev/null | grep -q "cube-studio"; then
            log_warning "强制删除现有 Kind 集群..."
            kind delete cluster --name cube-studio 2>/dev/null || true
            sleep 5
        fi
    else
        # 检查集群是否存在，如果存在则复用
        if kind get clusters 2>/dev/null | grep -q "cube-studio"; then
            log_info "检测到现有 Kind 集群，将复用以保留已下载的镜像"
            log_warning "如需强制重建集群，请设置环境变量: FORCE_REBUILD_CLUSTER=true"
        fi
    fi

    log_success "清理完成"
}

# 启动 Docker Compose
start_docker_compose() {
    log_info "步骤 1/13: 启动 Docker Compose 服务..."
    cd "$PROJECT_ROOT/install/docker"

    docker compose up -d
    
    # 等待 MySQL 就绪
    log_info "等待 MySQL 数据库启动..."
    for i in {1..30}; do
        if docker compose ps | grep -q "mysql.*Up.*healthy"; then
            log_success "MySQL 已就绪"
            break
        fi
        if [ $i -eq 30 ]; then
            log_error "MySQL 启动超时"
            exit 1
        fi
        sleep 2
    done
    
    log_success "Docker Compose 启动完成"
}

# 创建 Kind 集群
create_kind_cluster() {
    log_info "步骤 2/13: 创建 Kind Kubernetes 集群..."

    # 检查集群是否已存在
    if kind get clusters 2>/dev/null | grep -q "cube-studio"; then
        log_info "Kind 集群已存在，跳过创建步骤"

        # 验证集群状态
        if ! kubectl get nodes &>/dev/null; then
            log_error "集群存在但无法访问，请手动删除后重试: kind delete cluster --name cube-studio"
            exit 1
        fi
    else
        log_info "创建新的 Kind 集群..."
        kind create cluster --name cube-studio --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    protocol: TCP
EOF

        log_info "等待集群就绪..."
        sleep 30
    fi

    # 等待节点 Ready
    for i in {1..30}; do
        if kubectl get nodes | grep -q "cube-studio-control-plane.*Ready"; then
            log_success "Kind 集群就绪"
            break
        fi
        if [ $i -eq 30 ]; then
            log_error "Kind 集群启动超时"
            exit 1
        fi
        sleep 2
    done
}

sync_kubeconfig() {
    log_info "步骤 3/13: 同步 Kind kubeconfig..."

    local kubeconfig_dir="$PROJECT_ROOT/install/docker/kubeconfig"
    mkdir -p "$kubeconfig_dir"

    if kind get kubeconfig --name cube-studio --internal > "$kubeconfig_dir/dev-kubeconfig"; then
        chmod 600 "$kubeconfig_dir/dev-kubeconfig" 2>/dev/null || true
        log_success "kubeconfig 同步完成"
    else
        log_error "获取 kubeconfig 失败"
        exit 1
    fi
}

# 配置网络
configure_network() {
    log_info "步骤 4/13: 配置 Docker 与 Kind 网络..."

    # 将容器加入 Kind 网络
    docker network connect kind docker-myapp-1 2>/dev/null || true
    docker network connect kind docker-frontend-1 2>/dev/null || true
    docker network connect kind docker-mysql-1 2>/dev/null || true
    docker network connect kind docker-redis-1 2>/dev/null || true
    docker network connect kind docker-worker-1 2>/dev/null || true
    docker network connect kind docker-beat-1 2>/dev/null || true

    # 重启容器使网络生效（只重启存在的服务）
    cd "$PROJECT_ROOT/install/docker"
    docker compose restart myapp frontend 2>/dev/null || true

    log_info "等待网络配置生效..."
    sleep 20

    log_success "网络配置完成"
}

# 创建命名空间
create_namespaces() {
    log_info "步骤 5/13: 创建 Kubernetes 命名空间..."
    
    # aihub/kubeflow 命名空间供 Dashboard + Argo 部署使用
    for ns in infra pipeline jupyter automl service aihub kubeflow; do
        kubectl create namespace $ns 2>/dev/null || true
    done
    
    log_success "命名空间创建完成"
}

# 配置 RBAC
configure_rbac() {
    log_info "步骤 6/13: 配置 RBAC 权限..."

    if [ -f "$PROJECT_ROOT/install/kubernetes/sa-rbac.yaml" ]; then
        kubectl apply -f "$PROJECT_ROOT/install/kubernetes/sa-rbac.yaml"
        log_success "RBAC 配置完成"
    else
        log_warning "RBAC 配置文件未找到，跳过"
    fi
}

# 部署 K8s Dashboard
deploy_dashboard() {
    log_info "步骤 7/13: 部署 K8s Dashboard..."

    if [ -f "$PROJECT_ROOT/install/kubernetes/dashboard/v2.6.1-cluster.yaml" ]; then
        kubectl apply -f "$PROJECT_ROOT/install/kubernetes/dashboard/v2.6.1-cluster.yaml"
    fi

    if [ -f "$PROJECT_ROOT/install/kubernetes/dashboard/v2.6.1-user.yaml" ]; then
        kubectl apply -f "$PROJECT_ROOT/install/kubernetes/dashboard/v2.6.1-user.yaml"
    fi
    
    log_info "等待 Dashboard 启动..."
    sleep 20
    
    log_success "K8s Dashboard 部署完成"
}

# 暴露 Dashboard
expose_dashboard() {
    log_info "步骤 8/13: 暴露 K8s Dashboard..."
    
    # 删除默认服务
    kubectl delete svc kubernetes-dashboard-user1 -n kube-system 2>/dev/null || true
    
    # 创建 NodePort 服务
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-dashboard-nodeport
  namespace: kube-system
spec:
  type: NodePort
  selector:
    k8s-app: kubernetes-dashboard-user1
  ports:
  - port: 9090
    targetPort: 9090
    nodePort: 30080
EOF
    
    log_success "Dashboard 已暴露到端口 30080"
}

# 部署存储
deploy_storage() {
    log_info "步骤 9/13: 部署存储..."

    cd "$PROJECT_ROOT/install/kubernetes"

    for file in pv-pvc-pipeline.yaml pv-pvc-infra.yaml pv-pvc-jupyter.yaml pv-pvc-automl.yaml pv-pvc-service.yaml; do
        if [ -f "$file" ]; then
            kubectl apply -f $file
        fi
    done
    
    log_success "存储部署完成"
}

# 创建目录
create_directories() {
    log_info "步骤 10/13: 创建 Kind 容器内目录..."
    
    for dir in pipeline/workspace pipeline/archives global minio; do
        docker exec cube-studio-control-plane mkdir -p /data/k8s/kubeflow/$dir 2>/dev/null || true
    done
    
    log_success "目录创建完成"
}

# 部署 MinIO 和 Argo
deploy_workflows() {
    log_info "步骤 11/13: 部署 MinIO 和 Argo Workflows..."

    cd "$PROJECT_ROOT/install/kubernetes"

    if [ -f "argo/minio-pv-pvc-hostpath.yaml" ]; then
        kubectl apply -f argo/minio-pv-pvc-hostpath.yaml
    fi

    if [ -f "argo/pipeline-runner-rolebinding.yaml" ]; then
        kubectl apply -f argo/pipeline-runner-rolebinding.yaml
    fi

    if [ -f "argo/install-3.4.3-all.yaml" ]; then
        kubectl apply -f argo/install-3.4.3-all.yaml
    fi

    if [ -f "minio/minio-nodeport.yaml" ]; then
        kubectl apply -f minio/minio-nodeport.yaml
    fi
    
    log_info "等待工作流引擎启动..."
    sleep 30
    
    log_success "工作流引擎部署完成"
}

# 更新MinIO配置
update_minio_config() {
    log_info "步骤 11.5/13: 更新MinIO配置..."

    # 等待MinIO服务就绪
    log_info "等待MinIO服务就绪..."
    for i in {1..30}; do
        if kubectl get svc minio -n kubeflow &>/dev/null; then
            break
        fi
        if [ $i -eq 30 ]; then
            log_warning "MinIO服务未找到，跳过配置更新"
            return
        fi
        sleep 2
    done

    # 创建MinIO NodePort服务（如果不存在）
    if ! kubectl get svc minio-nodeport -n kubeflow &>/dev/null; then
        log_info "创建MinIO NodePort服务..."
        kubectl apply -f - > /dev/null 2>&1 <<EOF
apiVersion: v1
kind: Service
metadata:
  name: minio-nodeport
  namespace: kubeflow
spec:
  type: NodePort
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
    nodePort: 30900
  - name: console
    port: 9001
    targetPort: 9001
    nodePort: 30901
EOF
        log_success "MinIO NodePort服务已创建"
    else
        log_info "MinIO NodePort服务已存在"
    fi

    # 获取Kind节点IP
    KIND_NODE_IP=$(docker network inspect kind 2>/dev/null | grep -A 5 "cube-studio-control-plane" | grep IPv4Address | awk -F'"' '{print $4}' | cut -d'/' -f1)

    if [ -z "$KIND_NODE_IP" ]; then
        log_warning "无法获取Kind节点IP，跳过配置更新"
        return
    fi

    log_info "Kind节点IP: $KIND_NODE_IP"
    log_info "MinIO NodePort地址: $KIND_NODE_IP:30900"

    # 更新config.py中的MINIO_HOST
    if [ -f "$PROJECT_ROOT/install/docker/config.py" ]; then
        sed -i "s|MINIO_HOST = '.*'|MINIO_HOST = '${KIND_NODE_IP}:30900'  # MinIO NodePort地址(kind节点IP + NodePort)|g" "$PROJECT_ROOT/install/docker/config.py"
        log_success "MinIO配置已更新"
    else
        log_warning "未找到config.py文件"
    fi
}

# 添加节点标签
add_node_labels() {
    log_info "步骤 12/13: 添加节点标签..."
    
    kubectl label node cube-studio-control-plane \
        train=true \
        cpu=true \
        notebook=true \
        service=true \
        org=public \
        istio=true \
        kubeflow=true \
        kubeflow-dashboard=true \
        mysql=true \
        redis=true \
        monitoring=true \
        logging=true \
        --overwrite 2>/dev/null || true
    
    log_success "节点标签配置完成"
}

# 配置 Service
configure_service() {
    log_info "步骤 13/14: 配置 kubeflow-dashboard Service..."

    if [ -f "$PROJECT_ROOT/install/kubernetes/kubeflow-dashboard-service.yaml" ]; then
        kubectl apply -f "$PROJECT_ROOT/install/kubernetes/kubeflow-dashboard-service.yaml"
        log_success "Service 配置完成"
    else
        log_warning "Service 配置文件未找到，跳过"
    fi
}

# 部署 Cube Studio 到 Kubernetes
deploy_cube_to_k8s() {
    log_info "步骤 14/14: 部署 Cube Studio 到 Kubernetes..."

    # 修复 entrypoint.sh 换行符问题
    if [ -f "$PROJECT_ROOT/install/kubernetes/cube/overlays/config/entrypoint.sh" ]; then
        sed -i 's/\r$//' "$PROJECT_ROOT/install/kubernetes/cube/overlays/config/entrypoint.sh"
    fi

    # 获取 MySQL 和 Redis 在 kind 网络中的 IP
    MYSQL_IP=$(docker inspect docker-mysql-1 | grep -A 10 '"kind"' | grep '"IPAddress"' | awk -F'"' '{print $4}' | head -1)
    REDIS_IP=$(docker inspect docker-redis-1 | grep -A 10 '"kind"' | grep '"IPAddress"' | awk -F'"' '{print $4}' | head -1)

    if [ -z "$MYSQL_IP" ] || [ -z "$REDIS_IP" ]; then
        log_warning "无法获取 MySQL 或 Redis IP，跳过 Cube Studio 部署"
        return
    fi

    log_info "MySQL IP: $MYSQL_IP"
    log_info "Redis IP: $REDIS_IP"

    # 更新 kustomization.yml 中的配置
    cd "$PROJECT_ROOT/install/kubernetes/cube/overlays"

    # 备份原文件
    cp kustomization.yml kustomization.yml.bak

    # 更新配置
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=$REDIS_IP|g" kustomization.yml
    sed -i "s|MYSQL_SERVICE=.*|MYSQL_SERVICE=mysql+pymysql://root:admin@${MYSQL_IP}:3306/kubeflow?charset=utf8|g" kustomization.yml

    # 创建 kubernetes-config ConfigMap
    kubectl create configmap kubernetes-config -n infra --from-file="$PROJECT_ROOT/install/docker/kubeconfig/dev-kubeconfig" 2>/dev/null || true

    # 部署 Cube Studio
    log_info "应用 Kustomize 配置..."
    kubectl apply -k . 2>&1 | grep -v "Warning: 'vars' is deprecated"

    # 等待 Pod 启动
    log_info "等待 Cube Studio Pod 启动..."
    sleep 30

    # 检查部署状态
    kubectl get pods -n infra

    log_success "Cube Studio 部署完成"
}

# 验证系统
verify_system() {
    log_info "验证系统状态..."
    
    echo ""
    echo "=============================================================================="
    echo "  📊 系统状态检查"
    echo "=============================================================================="
    echo ""
    
    # 检查 Docker Compose
    echo -e "${BLUE}Docker Compose 服务:${NC}"
    cd "$PROJECT_ROOT/install/docker"
    docker compose ps
    echo ""
    
    # 检查 Kubernetes 节点
    echo -e "${BLUE}Kubernetes 节点:${NC}"
    kubectl get nodes
    echo ""
    
    # 检查 K8s Pods
    echo -e "${BLUE}Kubernetes Pods:${NC}"
    kubectl get pods -A
    echo ""
    
    # 检查 Dashboard
    if curl -s http://localhost:30080 > /dev/null 2>&1; then
        echo -e "${GREEN}✅ K8s Dashboard: http://localhost:30080${NC}"
    else
        echo -e "${YELLOW}⚠️  K8s Dashboard 尚未就绪，请稍后访问${NC}"
    fi
    
    # 检查 Cube Studio
    if curl -s http://localhost > /dev/null 2>&1; then
        echo -e "${GREEN}✅ Cube Studio: http://localhost${NC}"
    else
        echo -e "${YELLOW}⚠️  Cube Studio 尚未就绪，请稍后访问${NC}"
    fi
    
    echo ""
    log_success "系统验证完成"
}

# 打印访问信息
print_access_info() {
    echo ""
    echo "=============================================================================="
    echo "  🎉 启动完成！"
    echo "=============================================================================="
    echo ""
    echo "访问地址："
    echo "━━━━━━━━━━━━���━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Cube Studio 主站:     http://localhost"
    echo "  📊 K8s Dashboard:        http://localhost:30080"
    echo "  🤖 YOLOv8 推理服务:      http://localhost:8080 (可选)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "K8s Dashboard 登录 Token："
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    kubectl create token -n kube-system kubernetes-dashboard-user1 --duration=87600h 2>/dev/null || echo "  Token 稍后获取"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "常用命令："
    echo "  - 查看 myapp 日志:    cd $PROJECT_ROOT/install/docker && docker compose logs -f myapp"
    echo "  - 查看 K8s Pods:      kubectl get pods -A"
    echo "  - 停止所有服务:       cd $PROJECT_ROOT/install/docker && docker compose down"
    echo ""
    echo "=============================================================================="
    echo ""
}

# 主函数
main() {
    print_header
    
    check_dependencies
    cleanup_old_processes
    start_docker_compose
    create_kind_cluster
    sync_kubeconfig
    configure_network
    create_namespaces
    configure_rbac
    deploy_dashboard
    expose_dashboard
    deploy_storage
    create_directories
    deploy_workflows
    update_minio_config
    add_node_labels
    configure_service
    deploy_cube_to_k8s
    verify_system
    print_access_info
    
    log_success "Cube Studio 启动完成！"
}

# 错误处理
trap 'log_error "启动过程中发生错误，请检查日志"; exit 1' ERR

# 执行主函数
main
