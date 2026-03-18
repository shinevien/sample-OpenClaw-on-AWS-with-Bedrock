# OpenClaw Multi-Tenant Lab — One-Click Deployment

Deploy a fully functional OpenClaw multi-tenant AI assistant platform on AWS in ~15 minutes. No CLI required.

## 🚀 One-Click Deploy

Click the button below to launch in your AWS account:

| Region | Launch |
|--------|--------|
| **US East (N. Virginia)** | [![Launch Stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?stackName=openclaw-lab&templateURL=https://raw.githubusercontent.com/shinevien/sample-OpenClaw-on-AWS-with-Bedrock/main/clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml) |

> **Note:** If the Launch Stack button doesn't work (GitHub raw URLs may not load as S3), download the YAML first and upload manually — see [Manual Upload](#manual-upload) below.

## 📋 Prerequisites

- An AWS account with **Amazon Bedrock** model access enabled
  - Go to [Bedrock Console → Model access](https://us-east-1.console.aws.amazon.com/bedrock/home?region=us-east-1#/modelaccess) and enable the model you want to use
- IAM permissions to create CloudFormation stacks (Admin or PowerUser)

## 🛠 Deployment Steps

### Option A: Upload YAML Manually (Recommended)

1. Download [`clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml`](./clawdbot-bedrock-agentcore-multitenancy-oneclick.yaml)
2. Open [CloudFormation Console](https://us-east-1.console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create)
3. Choose **Upload a template file** → select the downloaded YAML
4. Fill in the parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| **Stack name** | `openclaw-lab` | Name your stack (use letters, numbers, hyphens) |
| **OpenClawModel** | `global.amazon.nova-2-lite-v1:0` | Bedrock model to use |
| **InstanceType** | `c7g.large` | EC2 instance type (Graviton recommended) |
| **KeyPairName** | *(empty)* | Optional SSH key pair |
| **PreBuiltImageUri** | `public.ecr.aws/y1x5g1o5/zhenghm/openclaw-multitenancy-agent:latest` | Pre-built container image (saves ~10min build time) |
| **GatewayToken** | *(empty)* | Optional custom access token |

5. Check **"I acknowledge that AWS CloudFormation might create IAM resources with custom names"**
6. Click **Create stack**
7. Wait ~15 minutes for deployment to complete

### Option B: AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name openclaw-lab \
  --template-body file://openclaw-multitenancy-oneclick.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

## 🎯 Access Your Assistant

Once the stack shows **CREATE_COMPLETE**:

1. Go to the **Outputs** tab of your CloudFormation stack
2. Find **GatewayPublicURL** — it contains the full URL with token in JSON format:
   ```json
   {"openclaw":"http://<IP>:18789/?token=<TOKEN>"}
   ```
3. Copy the URL and open it in your browser
4. Start chatting! 🎉

> **First message may take ~30 seconds** (cold start — AgentCore is spinning up a microVM for your session).

## 🏗 Architecture

```
User (Browser/Slack)
  ↓
OpenClaw Gateway (:18789)
  ↓
H2 Proxy (:8091) — translates Bedrock API to AgentCore calls
  ↓
Tenant Router (:8090) — routes by user/channel to isolated tenants
  ↓
AgentCore Runtime — each tenant gets an isolated microVM
  ↓
Amazon Bedrock — LLM inference
```

**Multi-tenant isolation:** Each user gets their own AgentCore microVM with separate workspace. Data is completely isolated between tenants.


## 🔧 Post-Deployment Configuration

### Connect Slack (Optional)

SSH to the EC2 instance and run:
```bash
openclaw config set channels.slack.enabled true
openclaw config set channels.slack.mode socket
openclaw config set channels.slack.appToken "xapp-..."
openclaw config set channels.slack.botToken "xoxb-..."
openclaw gateway restart
```

See [Slack Setup Guide](https://docs.openclaw.ai/channels/slack) for detailed instructions.

### Switch Model

```bash
# SSH to EC2
openclaw config set agents.defaults.model.primary "amazon-bedrock/global.anthropic.claude-sonnet-4-20250514-v1:0"
openclaw gateway restart
```

### Toggle Multi-Tenant Mode

```bash
# Disable (single-tenant, shared workspace)
systemctl --user stop h2-proxy tenant-router

# Enable (multi-tenant, isolated microVMs)
systemctl --user start h2-proxy tenant-router
```

## 🔍 Troubleshooting

### Check service status
```bash
systemctl --user status h2-proxy tenant-router openclaw-gateway
```

### View deployment log
```bash
cat /var/log/openclaw-setup.log
```

### View tenant router logs
```bash
journalctl --user -u tenant-router --no-pager -n 30
```

### "No response" error
The AgentCore Runtime ID may not be set. Check:
```bash
journalctl --user -u tenant-router --no-pager -n 5 | grep runtime
```
If it shows `NOT_SET`, manually set it:
```bash
RUNTIME_ID=$(aws bedrock-agentcore-control list-agent-runtimes --region us-east-1 \
  --query 'agentRuntimes[?status==`READY`].agentRuntimeId' --output text)
aws ssm put-parameter --name "/openclaw/$(hostname | xargs)/runtime-id" \
  --value "$RUNTIME_ID" --type String --overwrite --region us-east-1
systemctl --user restart tenant-router
```

### First message is slow (~30s)
Normal — this is the AgentCore cold start. Subsequent messages in the same session will be fast (~5s).

## 🧹 Cleanup

```bash
aws cloudformation delete-stack --stack-name openclaw-lab --region us-east-1
```

> **Note:** The S3 bucket has `VersioningConfiguration` enabled. If it contains objects, you may need to empty it before the stack can be fully deleted.

## 📚 Related Resources

- [OpenClaw Documentation](https://docs.openclaw.ai)
- [AgentCore Deployment Guide](./README_AGENTCORE.md)
- [Troubleshooting Supplements](./docs/agentcore-troubleshooting.md)
- [Original Multi-Tenant Template](./clawdbot-bedrock-agentcore-multitenancy.yaml)

## 📝 Changelog

Based on the [original multi-tenant template](./clawdbot-bedrock-agentcore-multitenancy.yaml) with the following enhancements:

- ✅ Docker build + ECR push automated in UserData
- ✅ AgentCore Runtime auto-created (with retry logic)
- ✅ H2 Proxy eventstream bug pre-fixed in fork
- ✅ H2 Proxy + Tenant Router as systemd services
- ✅ Gateway `bind=lan` + security group port 18789 for public access
- ✅ Template files auto-downloaded from GitHub
- ✅ boto3 auto-upgraded for AgentCore support
- ✅ SSM dynamic AMI resolution (no hardcoded AMI mapping)
- ✅ Pre-built image support (skip Docker build)
- ✅ Full URL with token in CloudFormation Outputs
- ✅ S3 bucket auto-naming to avoid delete/recreate conflicts
- ✅ Runtime name sanitization (hyphens → underscores)
