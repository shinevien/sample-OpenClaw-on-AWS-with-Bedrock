# OpenClaw Multi-Tenant on AgentCore — One-Click Lab Deployment

Deploy a fully functional OpenClaw multi-tenant AI assistant platform on AWS with Bedrock AgentCore in ~20 minutes.

## 📋 Prerequisites

- An AWS account with **Amazon Bedrock** model access enabled
  - Go to [Bedrock Console → Model access](https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess) and enable the model you want to use (default: Nova 2 Lite)
- IAM permissions to create CloudFormation stacks (`CAPABILITY_NAMED_IAM`)

## 🚀 Deployment

### Option A: Console (Recommended)

1. Download [`clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml`](./clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml)
2. Open [CloudFormation Console](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create)
3. Choose **Upload a template file** → select the downloaded YAML
4. Set **Stack name** (e.g. `openclaw-multitenancy`)
5. Review parameters (defaults work for most cases):

| Parameter | Default | Description |
|-----------|---------|-------------|
| OpenClawModel | `global.amazon.nova-2-lite-v1:0` | Bedrock model ID |
| InstanceType | `c7g.large` | EC2 type (Graviton recommended) |
| KeyPairName | *(empty)* | Optional SSH key pair |
| PreBuiltImageUri | *(empty)* | Pre-built image URI to skip Docker build |
| GatewayToken | *(empty)* | Custom access token (auto-generated if empty) |

6. Check **"I acknowledge that AWS CloudFormation might create IAM resources with custom names"**
7. Click **Create stack**
8. Wait ~20 minutes

### Option B: AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name openclaw-multitenancy \
  --template-body file://clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

## 🎯 Access Your Assistant

Once the stack shows **CREATE_COMPLETE**:

1. Go to the **Outputs** tab
2. Find **GatewayURL** — it contains the full URL with token:
   ```json
   {"openclaw":"http://<IP>:18789/?token=<TOKEN>"}
   ```
3. Copy the URL and open in your browser
4. Start chatting! 🎉

> **First message takes ~30 seconds** (AgentCore cold start — spinning up an isolated microVM).

### If Public IP Is Not Reachable

Use SSM Port Forwarding (see **SSMPortForwarding** output):

```bash
# 1. Install SSM plugin: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

# 2. Start port forwarding (from Outputs)
aws ssm start-session --target <InstanceId> --region us-east-1 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["18789"],"localPortNumber":["18789"]}'

# 3. Get token (from Outputs)
aws ssm get-parameter --name "/openclaw/<stack-name>/gateway-token" \
  --region us-east-1 --with-decryption --query 'Parameter.Value' --output text

# 4. Open http://localhost:18789/?token=<TOKEN>
```

## 🏗 Architecture

```
User (Browser / Slack)
  │
  ▼
OpenClaw Gateway (:18789)
  │
  ▼
H2 Proxy (:8091) ─── Bedrock Converse API → AgentCore invocation
  │
  ▼
Tenant Router (:8090) ─── Routes by user/channel
  │
  ▼
AgentCore Runtime ─── Isolated microVM per tenant
  │
  ▼
Amazon Bedrock ─── LLM inference
```

Each user gets their own isolated AgentCore microVM with separate workspace. Data is completely isolated between tenants.

## ⚙️ Resources Created

| Resource | Purpose |
|----------|---------|
| VPC + Subnets + IGW | Network infrastructure |
| EC2 Instance (Graviton) | Gateway + H2 Proxy + Tenant Router |
| ECR Repository | Agent container image |
| S3 Bucket | Tenant workspace persistence |
| IAM Roles (×2) | EC2 instance role + AgentCore execution role |
| SSM Parameters | Runtime ID, Gateway token |
| AgentCore Runtime | Isolated tenant microVMs |
| CloudWatch Log Group | Agent logs |

## 💰 Estimated Cost

| Component | Monthly Cost |
|-----------|-------------|
| EC2 c7g.large | ~$50 |
| S3 + ECR | ~$1-5 |
| Bedrock | Pay-per-use |
| **Total** | **~$55 + Bedrock usage** |

> **Tip:** Use `t4g.small` (~$12/month) for lighter workloads. Stop the instance when not in use.

## 🔧 Post-Deployment

### Connect Slack (Optional)

```bash
# SSH or SSM to EC2, then:
openclaw config set channels.slack.enabled true
openclaw config set channels.slack.mode socket
openclaw config set channels.slack.appToken "xapp-..."
openclaw config set channels.slack.botToken "xoxb-..."
openclaw gateway restart
```

### Change Model

```bash
openclaw config set agents.defaults.model.primary "amazon-bedrock/global.anthropic.claude-sonnet-4-20250514-v1:0"
openclaw gateway restart
```

## 🔍 Troubleshooting

| Problem | Solution |
|---------|----------|
| "No response" in chat | Runtime ID not set — check `journalctl --user -u tenant-router -n 5` |
| Page keeps loading | Public IP may be blocked — use SSM Port Forwarding |
| First message slow (~30s) | Normal cold start; subsequent messages are fast (~5s) |
| Stack creation failed | Check Events tab; common: missing Bedrock model access |

### View Logs

```bash
# Deployment log
cat /var/log/openclaw-setup.log

# Service status
systemctl --user status h2-proxy tenant-router openclaw-gateway

# Tenant Router logs
journalctl --user -u tenant-router --no-pager -n 30
```

## 🧹 Cleanup

```bash
aws cloudformation delete-stack --stack-name openclaw-multitenancy --region us-east-1
```

> **Note:** Empty the S3 bucket first if it contains objects.

## 📚 Related

- [OpenClaw Docs](https://docs.openclaw.ai)
- [AgentCore Manual Deployment Guide](./README_AGENTCORE.md)
- [Original Multi-Tenant Template](./clawdbot-bedrock-agentcore-multitenancy.yaml)
- [Single-Tenant Template](./clawdbot-bedrock.yaml)

## 📝 What This Template Adds

Compared to the [original multi-tenant template](./clawdbot-bedrock-agentcore-multitenancy.yaml), this one-click version automates all manual post-deployment steps:

- ✅ Docker build + ECR push in UserData
- ✅ AgentCore Runtime auto-created (with retry)
- ✅ H2 Proxy + Tenant Router as systemd services
- ✅ Gateway `bind=lan` + security group port 18789
- ✅ Template files auto-downloaded
- ✅ boto3 auto-upgraded for AgentCore support
- ✅ SSM dynamic AMI (no hardcoded AMI mapping)
- ✅ Pre-built image support (`PreBuiltImageUri` parameter)
- ✅ Full URL with token in CloudFormation Outputs
- ✅ S3 bucket auto-naming (no delete/recreate conflicts)
- ✅ Runtime name sanitization (hyphens → underscores)
- ✅ Eventstream fix pre-applied in [fork](https://github.com/shinevien/sample-OpenClaw-on-AWS-with-Bedrock)
