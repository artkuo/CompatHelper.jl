const LOCAL_REPO_NAME = "REPO"
const GIT_COMMIT_NAME = "CompatHelper Julia"
const GIT_COMMIT_EMAIL = "compathelper_noreply@julialang.org"

function add_compat_section!(project::AbstractDict)
    if !haskey(project, "compat")
        project["compat"] = Dict{Any,Any}()
    end

    return project
end

function get_project_deps(
    api::GitHub.GitHubAPI,
    clone_hostname::AbstractString,
    repo::GitHub.Repo;
    subdir::AbstractString="",
    include_jll::Bool=false,
)
    mktempdir() do f
        url_with_auth = "https://x-access-token:$(api.token)@$(clone_hostname)/$(repo.full_name).git"
        local_path = joinpath(f, LOCAL_REPO_NAME)
        @mock git_clone(url_with_auth, local_path)

        # Get all the compat dependencies from the local Project.toml file
        project_file = @mock joinpath(local_path, subdir, "Project.toml")
        deps = get_project_deps(project_file; include_jll=include_jll)

        return deps
    end
end

function get_project_deps(project_file::AbstractString; include_jll::Bool=false)
    project_deps = Set{CompatEntry}()
    project = TOML.parsefile(project_file)

    if haskey(project, "deps")
        deps = project["deps"]
        add_compat_section!(project)
        compat = project["compat"]

        for dep in deps
            name = dep[1]
            uuid = UUIDs.UUID(dep[2])

            # Ignore STDLIB packages and JLL ones if flag set
            if !Pkg.Types.is_stdlib(uuid) &&
               (!endswith(lowercase(strip(name)), "_jll") || include_jll)
                package = Package(name, uuid)
                compat_entry = CompatEntry(package)
                dep_entry = convert(String, strip(get(compat, name, "")))

                if !isempty(dep_entry)
                    compat_entry.version_spec = VersionSpec(dep_entry)
                    compat_entry.version_verbatim = dep_entry
                end

                push!(project_deps, compat_entry)
            end
        end
    end

    return project_deps
end

function clone_all_registries(f::Function, registry_list::Vector{Pkg.RegistrySpec})
    registry_temp_dirs = Vector{String}()

    for registry in registry_list
        tmp_dir = @mock mktempdir(; cleanup=true)
        local_registry_path = joinpath(tmp_dir, registry.name)
        push!(registry_temp_dirs, local_registry_path)
        @mock git_clone(registry.url, local_registry_path)
    end

    f(registry_temp_dirs)

    for tmp_dir in registry_temp_dirs
        @mock rm(tmp_dir; force=true, recursive=true)
    end
end

function get_latest_version_from_registries!(
    deps::Set{CompatEntry}, registry_list::Vector{Pkg.RegistrySpec}
)
    @mock clone_all_registries(registry_list) do registry_temp_dirs
        for registry in registry_temp_dirs
            registry_toml_path = joinpath(registry, "Registry.toml")
            registry_toml = TOML.parsefile(joinpath(registry_toml_path))
            packages = registry_toml["packages"]

            for dep in deps
                uuid = string(dep.package.uuid)

                if uuid in keys(packages)
                    versions_toml_path = joinpath(
                        registry, packages[uuid]["path"], "Versions.toml"
                    )
                    versions = VersionNumber.(collect(keys(TOML.parsefile(versions_toml_path))))

                    max_version = maximum(versions)
                    dep.latest_version = _max(dep.latest_version, max_version)
                end
            end
        end
    end
    
    return deps
end
