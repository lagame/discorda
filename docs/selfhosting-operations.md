# Operação do servidor de casa

Execute os comandos na raiz do clone, em PowerShell 7. Esta instalação é independente do piloto antigo. Não substitui nem importa automaticamente o banco existente.

## Comandos diários

```powershell
# Iniciar/compilar e conferir readiness
pwsh -File tools/start-selfhost.ps1
# Ver estado e logs
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml ps -a
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml logs --tail 100 api livekit migrate
# Parar, preservando dados
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml stop
```

Habilite o início do Docker Desktop ao entrar no Windows. `restart: unless-stopped` reinicia os serviços após reiniciar a engine; um serviço parado manualmente precisa ser iniciado novamente. O Radmin também deve estar conectado.

### LiveKit nativo no Windows

No piloto que usa `.discorda/selfhost/livekit-native.yaml`, `start-selfhost.ps1` detecta esse arquivo, mantém o LiveKit Docker parado e inicia o binário Windows em `artifacts/media-lab/server/livekit-server.exe`. O PostgreSQL e a API continuam no Docker. Após reiniciar o Windows, conecte o Radmin, espere o Docker Desktop iniciar e execute `pwsh -File tools/start-selfhost.ps1`; o LiveKit nativo não inicia sozinho. Preserve o binário nesse caminho, ou baixe novamente com `pwsh -File tools/media-lab/setup-windows.ps1` antes de iniciar. Instalações sem esse arquivo continuam usando LiveKit Docker.

Execute `pwsh -File tools/check-selfhost.ps1` antes de convidar amigos. O Windows pode criar permissões amplas de entrada para `livekit-server.exe`. Depois de cadastrar os IPs Radmin dos amigos no painel e aplicar o script de Firewall gerado pelo painel como administrador, desabilite as duas regras automáticas amplas de entrada do `livekit-server.exe` no Firewall do Windows. Confira o caminho do executável nas propriedades da regra para não alterar outro programa. As regras `Discorda SelfHost ICE TCP` e `Discorda SelfHost ICE UDP` devem permanecer ativas e restritas aos IPs cadastrados. Repita a checagem; ela deve deixar de apontar a permissão ampla. Só então teste voz em dois computadores.

Se precisar voltar ao LiveKit Docker neste piloto, execute `pwsh -File tools/restore-docker-media.ps1` com a configuração privada de backup ainda presente. Esse comando interrompe chamadas, restaura `settings.json`, o reinício automático do contêiner e a API. A reversão não foi executada neste piloto enquanto a mídia nativa funciona.

Não use `down -v` no servidor: isso apaga os volumes do banco e da política de rede. Logs podem conter metadados de operação e devem ser revisados antes de anexar em issues.

## Onde ficam as configurações

| Dado | Local | Como alterar |
| --- | --- | --- |
| E-mails autorizados e sessões | PostgreSQL local | Painel administrativo |
| E-mail administrador | `.discorda/selfhost/settings.json`, `Admin.Email` | Alterar no host e reiniciar/migrar; novo e-mail deve ser seu |
| Lista desejada de IPs Radmin | Volume `state`, `network.json` | Painel; baixar e aplicar Firewall depois |
| Provedor Google | Supabase | Painel com PAT ou dashboard Supabase |
| URL e publishable key | `settings.json`, `Supabase` | Configuração no host; reiniciar API |
| Senha PostgreSQL | `postgres-password` e `settings.json` | Rotacionar no PostgreSQL e sincronizar arquivos |
| Chave/secret LiveKit | `livekit.yaml` e `settings.json` | Alterar ambos e recriar API/LiveKit |
| Certificado e senha PFX | `server.pfx` e `settings.json` | Renovar e redistribuir conexão |

O painel não devolve senhas. Arquivos privados no host são protegidos por ACL Windows, mas **não são um cofre criptografado**; usuários com controle administrativo do host/Docker podem lê-los. Guarde backups criptografados. O administrador deve ter MFA nas contas Google/Supabase.

`DISCORDA_CONFIG_FILE` informa à API o JSON da implantação. Ele tem precedência sobre a configuração padrão e é lido ao iniciar. Edite somente esse arquivo para a implantação Docker. Não troque o projeto Supabase de uma instalação com usuários existentes sem planejar migração: as identidades ficam vinculadas ao emissor e subject originais.

## Backup

Crie uma pasta privada fora do repositório. Para o banco, gere o arquivo dentro do container e copie-o sem redirecionar binário pelo PowerShell:

```powershell
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml exec -T postgres pg_dump -U discorda -d discorda -Fc -f /tmp/discorda-backup.dump
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml cp postgres:/tmp/discorda-backup.dump .discorda/selfhost/database-backup.dump
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml cp api:/app/state/network.json .discorda/selfhost/network-backup.json
```

O último comando só funciona depois de salvar a primeira lista no painel. Copie a pasta `.discorda/selfhost` inteira para armazenamento privado/criptografado. Ela contém segredos e certificado. O provedor Google e seus usuários de autenticação continuam no projeto Supabase: o dump local não os inclui.

Para restaurar em uma **instância nova e vazia**, restaure primeiro os arquivos privados, suba PostgreSQL sozinho, copie o dump e use `pg_restore -U discorda -d discorda --no-owner --no-privileges --exit-on-error /tmp/discorda-backup.dump`. Não restaure em cima de um banco em uso. Depois execute `start-selfhost.ps1`, restaure a lista pelo painel e reaplique o Firewall. Preserve a mesma URL Supabase para manter identidades. Teste o procedimento antes de depender do backup.

## Atualizar

A API usa `discorda_runtime`; somente a migration recebe a conta administrativa de `migration.json`. Os scripts de início separam as contas de instalações antigas geradas pelo assistente. Consulte [a atualização de segurança](security-audit.md) para configurações customizadas. Preserve ambos os JSONs nos backups. PostgreSQL passa de 17.9 para 17.11, na mesma família Alpine 3.23; essa troca reinicia o banco e requer janela de manutenção.

Faça backup antes. Baixe/revise a versão desejada, então execute `start-selfhost.ps1`. As migrations são um serviço separado; falha de migration impede a nova API de iniciar. Uma migration aplicada pode não ser compatível com rollback de código: para reverter, use código e backup compatíveis em conjunto. Nunca troque a tag major do PostgreSQL sem migração planejada.

Atualização do desktop é independente da atualização do servidor. O mantenedor gera releases assinadas; builds comunitárias precisam de reinstalação manual ou configurar seu próprio canal assinado. Consulte o README.

## Recuperar acesso administrativo

Se o Google deixou de funcionar, corrija o provedor no dashboard Supabase. Se apenas o e-mail administrador mudou, edite `Admin.Email` em `settings.json` e `migration.json`, execute o serviço de migration para autorizar o novo e-mail e recrie a API:

```powershell
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml run --rm migrate
docker compose --env-file .discorda/selfhost/compose.env -f infra/compose/selfhost.yml up -d --force-recreate api
```

Para bloquear explicitamente o e-mail antigo após entrar: use o painel. A troca de administrador não apaga automaticamente a conta antiga nem seus dados. Na versão 0.9, o administrador anterior perde também a criação de canais: a API confere o e-mail configurado em cada operação.

## Rotacionar secrets e certificado

A senha do PostgreSQL não muda quando você simplesmente edita `postgres-password` em um volume já inicializado. Faça a alteração no banco usando `psql` e `\password discorda` (prompt de senha, evitando histórico com segredo), atualize `postgres-password` e a conexão administrativa de `migration.json`. A API usa uma conta diferente: para rotacioná-la, execute `\password discorda_runtime`, atualize a conexão de `settings.json` e `Migration.RuntimePassword` de `migration.json`, e recrie a API. A migration não redefine a senha de uma conta já existente. Chaves LiveKit devem coincidir nos dois arquivos e exigem recriar os serviços; isso interrompe chamadas.

O certificado gerado vence em um ano. Renove antes do vencimento usando uma CA privada e SAN com o IP do host, exporte o novo PFX, atualize o caminho/senha no JSON e gere outro arquivo de conexão com os certificados públicos. Todos os clientes precisam reimportar a conexão, pois o aplicativo fixa o certificado. Guarde a CA com segurança. Não há renovação automática nesta versão.

## Problemas comuns

- **Porta ocupada:** pare a implantação antiga que usa 7443/7881/7882 antes de migrar. Não finalize processos desconhecidos.
- **Login redireciona errado:** confira as três Redirect URLs do README: `localhost` para o painel e portas `3000` e `3001` em `127.0.0.1` para o desktop. Não são intercambiáveis.
- **Login permitido pelo Google, negado no app:** autorize o mesmo e-mail na lista do Discorda. O provedor deve ser Google e o e-mail confirmado.
- **Sem áudio/vídeo entre PCs:** execute `pwsh -File tools/check-selfhost.ps1` no host. Ambos precisam estar na mesma rede Radmin, com IPs corretos no Firewall. Verifique UDP 7882 e TCP 7881, regras do processo ativo (Docker ou LiveKit nativo) e `rtc.node_ip`. Uma regra de bloqueio prevalece sobre uma regra de permissão; revise exceções limitadas à interface Radmin, sem liberar o Docker inteiro. Conectar ao chat ou receber resposta de `/health/ready` não comprova conectividade de mídia. Mesmo sem bloqueio explícito, o encaminhamento UDP do Docker Desktop no Windows pode falhar; confirme a chamada em dois computadores antes de convidar o grupo.
- **Readiness 503:** confira saúde do banco e saída do serviço migrate. Não envie arquivos privados para diagnóstico.
- **Reinício alterou IP Radmin:** IP é usado em Compose, LiveKit, URL pública e SAN do certificado. Atualize os quatro e redistribua a conexão.
- **A API antiga ainda atende:** a implantação Docker usa dados próprios. Planeje exportação/importação e janela de troca, mantendo backup; não execute dois servidores no mesmo IP/portas.

## Migrar o piloto existente

Mantenha a instalação nativa funcionando enquanto prepara e testa a Docker em ambiente separado. Faça dump do PostgreSQL antigo e backup dos seus user-secrets. Restaure o dump em PostgreSQL Docker vazio; mantenha o mesmo projeto Supabase, mas gere secrets LiveKit/certificado próprios para a nova implantação. Pare o piloto apenas na janela de troca, confira readiness e valide com dois usuários. Guarde a configuração antiga para rollback. Não há migração automática nem alteração do seu Firewall durante o assistente.
