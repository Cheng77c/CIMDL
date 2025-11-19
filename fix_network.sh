#!/bin/bash

# ==============================================================================
# Cube Studio 网络修复脚本
# ==============================================================================
# 说明：修复重启后在线调试和在线日志无法访问的问题
# 作者：Claude Code
# 创建时间：2025-11-19
# ==============================================================================

set -e

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

echo ""
echo "=============================================================================="
echo "  🔧 Cube Studio 网络修复脚本"
echo "=============================================================================="
echo ""

# 步骤1: 连接frontend到kind网络
log_info "步骤 1/3: 连接frontend到kind网络..."
if docker network connect kind docker-frontend-1 2>&1 | grep -q "already exists"; then
    log_warning "frontend已连接到kind网络"
else
    log_success "frontend已成功连接到kind网络"
fi

# 步骤2: 配置MinIO NodePort访问
log_info "步骤 2/3: 配置MinIO NodePort访问..."

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
else
    log_info "Kind节点IP: $KIND_NODE_IP"
    log_info "MinIO NodePort地址: $KIND_NODE_IP:30900"

    # 更新config.py中的MINIO_HOST
    if grep -q "MINIO_HOST = " "$PROJECT_ROOT/install/docker/config.py"; then
        sed -i "s|MINIO_HOST = '.*'|MINIO_HOST = '${KIND_NODE_IP}:30900'  # MinIO NodePort地址(kind节点IP + NodePort)|g" "$PROJECT_ROOT/install/docker/config.py"
        log_success "MinIO配置已更新"
    else
        log_warning "未找到MINIO_HOST配置"
    fi
fi

# 步骤3: 连接MySQL和Redis到kind网络
log_info "步骤 3/5: 连接MySQL和Redis到kind网络..."
docker network connect kind docker-mysql-1 2>/dev/null || true
docker network connect kind docker-redis-1 2>/dev/null || true
log_success "MySQL和Redis已连接到kind网络"

# 步骤4: 部署Cube Studio到Kubernetes
log_info "步骤 4/5: 部署Cube Studio到Kubernetes..."

# 修复entrypoint.sh换行符
if [ -f "$PROJECT_ROOT/install/kubernetes/cube/overlays/config/entrypoint.sh" ]; then
    sed -i 's/\r$//' "$PROJECT_ROOT/install/kubernetes/cube/overlays/config/entrypoint.sh"
fi

# 获取MySQL和Redis IP
MYSQL_IP=$(docker inspect docker-mysql-1 | grep -A 10 '"kind"' | grep '"IPAddress"' | awk -F'"' '{print $4}' | head -1)
REDIS_IP=$(docker inspect docker-redis-1 | grep -A 10 '"kind"' | grep '"IPAddress"' | awk -F'"' '{print $4}' | head -1)

if [ ! -z "$MYSQL_IP" ] && [ ! -z "$REDIS_IP" ]; then
    log_info "MySQL IP: $MYSQL_IP"
    log_info "Redis IP: $REDIS_IP"

    # 更新kustomization.yml
    cd "$PROJECT_ROOT/install/kubernetes/cube/overlays"
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=$REDIS_IP|g" kustomization.yml
    sed -i "s|MYSQL_SERVICE=.*|MYSQL_SERVICE=mysql+pymysql://root:admin@${MYSQL_IP}:3306/kubeflow?charset=utf8|g" kustomization.yml

    # 创建kubernetes-config ConfigMap
    kubectl create configmap kubernetes-config -n infra --from-file="$PROJECT_ROOT/install/docker/kubeconfig/dev-kubeconfig" 2>/dev/null || true

    # 部署Cube Studio
    kubectl apply -k . 2>&1 | grep -v "Warning"

    log_success "Cube Studio已部署到Kubernetes"
else
    log_warning "无法获取MySQL或Redis IP，跳过Cube Studio部署"
fi

# 步骤5: 重启服务
log_info "步骤 5/5: 重启myapp和frontend服务..."
cd "$PROJECT_ROOT/install/docker"
docker compose restart myapp frontend 2>/dev/null || true

log_success "服务重启完成"

# 等待服务启动
log_info "等待服务启动..."
sleep 10

# 验证
echo ""
echo "=============================================================================="
echo "  📊 验证修复结果"
echo "=============================================================================="
echo ""

# 检查frontend网络
if docker inspect docker-frontend-1 | grep -q '"kind"'; then
    echo -e "${GREEN}✅ frontend已连接到kind网络${NC}"
else
    echo -e "${YELLOW}⚠️  frontend未连接到kind网络${NC}"
fi

# 检查K8s Dashboard
if curl -s -I http://localhost/k8s/dashboard/user1/ 2>/dev/null | grep -q "200 OK"; then
    echo -e "${GREEN}✅ K8s Dashboard访问正常${NC}"
else
    echo -e "${YELLOW}⚠️  K8s Dashboard访问失败${NC}"
fi

# 检查MinIO配置
CURRENT_MINIO=$(grep "MINIO_HOST = " "$PROJECT_ROOT/install/docker/config.py" | cut -d"'" -f2)
echo -e "${BLUE}📝 当前MinIO配置: ${CURRENT_MINIO}${NC}"

echo ""
log_success "修复完成！"
echo ""
echo "如果问题仍然存在，请检查："
echo "  1. Kind集群是否正常运行: kubectl get nodes"
echo "  2. MinIO服务是否正常: kubectl get svc minio -n kubeflow"
echo "  3. 查看myapp日志: cd $PROJECT_ROOT/install/docker && docker compose logs -f myapp"
echo ""
