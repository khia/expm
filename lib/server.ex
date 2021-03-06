defmodule Expm.Server do
  use Application.Behaviour
  alias GenX.Supervisor, as: Sup
  alias :cowboy, as: Cowboy

  def start(_, _) do
   env = Application.environment(:expm)
   static_dir = File.join [File.dirname(:code.which(__MODULE__)), "..", "priv", "static"]
   {repository, _} = Code.eval env[:repository], [env: env]
   dispatch = [
      {:_, [{[], Expm.Server.Http, [repository: repository, endpoint: :list]},     
            {["favicon.ico"], :cowboy_static, [file: "favicon.ico", directory: static_dir]},     
            {["#{Expm.version}","expm"], :cowboy_static, [file: "expm", directory: static_dir]},                 
            {["s",:'...'], :cowboy_static, [directory: static_dir, mimetypes: {function(:mimetypes,:path_to_mimes,2), :default}]},     
            {["__version__"], Expm.Server.Http, [repository: repository, endpoint: :version]},      
            {[:package], Expm.Server.Http, [repository: repository, endpoint: :package]},      
            {[:package, :version], Expm.Server.Http, [repository: repository, endpoint: :package_version]},
            ]},
   ]
   http_port = env[:http_port]
   Cowboy.start_http Expm.Server.Http.Listener, 100, [port: http_port], [dispatch: dispatch]
   Lager.info "Started expm server on port #{http_port}"
   Sup.start_link sup_tree
  end

  defp sup_tree do
    Sup.OneForOne.new(id: Expm.Server.Sup)
  end
end

defmodule Expm.Server.Http do

  alias :cowboy_req, as: Req

  defrecord State, opts: [], endpoint: nil, repository: nil

  def init({:tcp, :http}, _req, _opts) do
    {:upgrade, :protocol, :cowboy_rest}
  end

  def rest_init(req, opts) do
    repository = Expm.Repository.Auth.new repository: opts[:repository]  
    {:ok, req, State.new(opts: opts, endpoint: opts[:endpoint], repository: repository)}
  end

  def is_authorized(req, State[endpoint: :package] = state) do
    case Req.method(req) do
      {"GET",req} -> {true, req, state}
      {_, req} ->
        {auth, req} = Req.header("authorization", req)
        case auth do 
          :undefined -> {{false, %b{Basic realm="expm"}}, req, state}
          _ ->
              ["Basic", auth] = String.split(auth, " ")
              [username, auth] = String.split(:base64.decode(auth), ":")
              # I know this isn't strong enough, but it generates predictable auth tokens
              # (which is what Auth currently needs)
              auth = :crypto.hash(:sha256, auth) 
              repository = Expm.Repository.Auth.new username: username, 
                                                    auth_token: auth, 
                                                    repository: state.opts[:repository]
              {true, req, state.repository(repository)}
        end
      end
  end
  def is_authorized(req, state) do
    {true, req, state}
  end

  def allowed_methods(req, state) do
    {["GET", "PUT", "POST", "DELETE"], req, state}
  end

  def content_types_provided(req, State[] = state) do
    {[
       {{<<"text">>, <<"html">>, []}, :to_html},      
       {{<<"application">>, <<"elixir">>, []}, :to_elixir},
     ], req, state}
  end

  def content_types_accepted(req, state) do
    {[{{"application","elixir", []}, :process_elixir}], req, state}
  end

  def process_elixir(req, State[endpoint: :package, repository: repository] = state) do
    {:ok, body, req} = Req.body(req)
    pkg = Expm.Package.decode body
    case Expm.Repository.put(repository, pkg) do
      Expm.Package[] = pkg ->
        Lager.info "Published #{pkg.name}:#{pkg.version}"    
        req = Req.set_resp_body(pkg.encode, req)
        {true, req, state}
      other ->
        Lager.error "Failed publishing #{pkg.name} :: #{pkg.version}: #{inspect other}"
        req = Req.set_resp_body(inspect(other), req)                
        {true, req, state}
    end
  end

  def process_elixir(req, State[endpoint: :list, repository: repository] = state) do
    {:ok, body, req} = Req.body(req)
    filter = Expm.Package.decode body  
    pkgs = Expm.Package.filter repository, filter
    req = Req.set_resp_body(inspect(pkgs), req)
    {true, req, state}
  end

  def to_html(req, State[endpoint: :version] = state) do
    out = Expm.version
    {out, req, state}
  end

  def to_html(req, State[endpoint: :list, repository: repository] = state) do
    {kwd, req} = Req.qs_val("q", req, "")
    pkgs = Expm.Package.search repository, kwd    
    out = render_page(Expm.Server.Templates.list(pkgs, (if kwd == "", do: "Index", else: "Search: #{kwd}")), req, state)
    {out, req, state}
  end

  def to_html(req, State[endpoint: :package, repository: repository] = state) do
    {package, req} = Req.binding(:package, req)  
    pkg = Expm.Package.fetch repository, package
    if pkg == :not_found, do: pkg = "ERROR: No such package"    
    out = render_page(Expm.Server.Templates.package(pkg, repository), req, state)
    {out, req, state}
  end

  def to_html(req, State[endpoint: :package_version, repository: repository] = state) do
    {package, req} = Req.binding(:package, req)  
    {version, req} = Req.binding(:version, req)    
    pkg = Expm.Package.fetch repository, package, version
    if pkg == :not_found, do: pkg = "ERROR: No such package"
    out = render_page(Expm.Server.Templates.package(pkg, repository), req, state)
    {out, req, state}
  end

  def to_elixir(req, State[endpoint: :package_version, repository: repository] = state) do
    {package, req} = Req.binding(:package, req)
    {version, req} = Req.binding(:version, req)
    pkg = Expm.Package.fetch repository, package, version
    {pkg.encode, req, state}
  end

  def to_elixir(req, State[endpoint: :package, repository: repository] = state) do
    {package, req} = Req.binding(:package, req)
    versions = Expm.Package.versions repository, package
    {inspect(versions), req, state}
  end

  defp render_page(content, req, state) do
    Expm.Server.Templates.page(content, page_assigns(req, state))
  end

  defp page_assigns(req, _state) do
    {host, req} = Req.host(req)
    {port, req} = Req.port(req)
    motd_file = File.join [File.dirname(__FILE__), "..", "priv", "motd"]
    if File.exists?(motd_file) do
      {:ok, motd} = File.read(motd_file)
    else
      motd = ""
    end    
    if port == 80 do
      port = ""
    else
      port = ":#{port}"
    end  
    [host: host, port: port, motd: motd]
  end


 def terminate(_req, _state), do: :ok
end