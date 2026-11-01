# Diagram prompt (copy everything below into an image-generation model)

Create a clean, professional cloud infrastructure diagram, 16:9 landscape, white background, flat vector style, large readable labels, thin dark-grey lines, soft pastel fills. Title at the top: "Configuration Management with Ansible: everything on one EC2 instance".

LAYOUT, left to right.

LEFT: a "Browser (your laptop)" box with two items: "http://<EC2-PUBLIC-IP>:8081/ (web1)" and "http://<EC2-PUBLIC-IP>:8082/ (web2)". Solid arrows labeled "HTTP 8081" and "HTTP 8082" go to the right. Below it a small "Terminal (SSH port 22)" box with a dashed arrow to the right.

MIDDLE: a thin firewall icon labeled "Security group: inbound SSH 22 and TCP 8081-8082, all from my IP only; outbound all".

RIGHT: a large AWS-orange-bordered box labeled "AWS Region > Default VPC > EC2 instance m7i-flex.large (Ubuntu 24.04, 2 vCPU, 8 GiB)". Inside it, one big blue rounded box labeled "Docker Engine (private network ansible-lab_default)". Inside the Docker box:
1. On the left, a green box "control: Ansible control container (ansible-core 2.18)" containing four small boxes: "inventory (web1, web2, tools1)", "playbooks: site, rolling, verify", "roles: common, nginx_site, toolbox", "Ansible Vault (encrypted secret)".
2. On the right, three server boxes drawn like small servers: "web1 (Ubuntu + SSH + nginx) :8081", "web2 (Ubuntu + SSH + nginx) :8082", "tools1 (Ubuntu + SSH + cron)". Group web1 and web2 with a dashed outline labeled "group: web".

Numbered arrows, each with a short label:
1. Terminal to control: "ansible-playbook site.yml".
2. Control to each of the three servers: "SSH (key login, private network only)".
3. Control to servers: "install packages, write config from templates, start services".
4. Vault box to web servers, green arrow: "secret delivered to a root-only file".
5. Servers back to control: "changed / ok report (second run: changed=0)".
6. A red arrow from a hand icon labeled "manual edit (drift)" to web1, then a dashed arrow from control labeled "--check --diff shows it, a real run repairs it".
7. Control to web1 then web2: "rolling update: one at a time, health check in between".
8. Browser to web1 and web2: "page says Managed by Ansible".

Add a small legend: blue = public entry point, green = Ansible and secrets, red = manual change (drift). Add a footer note: "SSH is never opened to the internet; the servers are containers on this one instance. No other AWS services are used."

Do not add any AWS services (no Systems Manager, Secrets Manager, IAM, ALB). Use generic icons, no brand logos other than a simple Docker whale. Make sure all text is spelled exactly as written above.
