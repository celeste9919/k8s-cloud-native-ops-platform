<%@ page language="java" contentType="text/html; charset=UTF-8" pageEncoding="UTF-8"%>
<html>
<head><title>Demo App</title></head>
<body>
<h2>Hello, Demo App!</h2>
<p>这是一个部署在 Kubernetes Tomcat 里的示例 Web 应用。</p>
<p>当前时间: <%= new java.util.Date() %></p>
<p>容器主机名: <%= java.net.InetAddress.getLocalHost().getHostName() %></p>
<p>构建版本: v1 (由 GitLab CI/CD 构建)</p>
</body>
</html>
