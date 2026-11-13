# Repository selection

Approved by the interviewer before implementation.

## A – modern: [NimblePros/eShopOnWeb](https://github.com/NimblePros/eShopOnWeb) → [fork](https://github.com/bilalmushtaq514/eShopOnWeb)

* ASP.NET Core on **.NET 10** (LTS, supported until Nov 2028): `global.json` pins SDK 10, all projects `net10.0`. MIT.
* The maintained continuation of Microsoft's archived `dotnet-architecture/eShopOnWeb`. Clean Architecture, MVC + Razor Pages + Blazor admin, Identity.
* Built and tested with no external services, verified before choosing: 44 unit, 3 integration and 12 functional tests pass.
* `UseOnlyInMemoryDatabase` swaps SQL Server for EF Core in-memory, so there's nothing extra to pay for.

### Changes in the fork (kept minimal)
| File | Change |
|---|---|
| `src/Web/Dockerfile` | Rewritten: multi-stage, cached restore layer, non-root, build version baked in |
| `.dockerignore` | Tightened (no tests/docs/secrets/sample key in the context) |
| `src/Web/Program.cs` | +2 lines: `/health/live`, `/health/ready` (the existing `/health` also probes the PublicApi, which isn't deployed) |
| `src/Web/Views/Shared/_Layout.cshtml` | Build + pod banner |
| `deploy/k8s/**` | Kustomize base + dev overlay |
| `azure-pipelines.yml` | Pipeline A |

No application logic was changed. Runtime config only: `ASPNETCORE_ENVIRONMENT=Docker`,
`UseOnlyInMemoryDatabase=true`, `Aspire__Seq__DisableHealthChecks=true` (the Aspire Seq
integration otherwise refuses to start without a Seq server, which I found while testing the container locally).

## B – legacy: [dotnet-architecture/eShopModernizing](https://github.com/dotnet-architecture/eShopModernizing) → [fork](https://github.com/bilalmushtaq514/eShopModernizing), project `eShopLegacyMVCSolution/src/eShopLegacyMVC`

* ASP.NET **MVC 5** on **.NET Framework 4.7.2**: classic non-SDK `.csproj`, NuGet + **MSBuild**, runs on IIS / CLR v4.0. MIT.
* Microsoft's own "legacy app to modernise" sample, with a typical legacy stack: Autofac, EF6, log4net, App Insights SDK, Web.config transforms.
* **Database decision:** the app's built-in `UseMockData` switch replaces EF6/SQL Server with the in-memory `CatalogServiceMock`. That costs nothing and keeps the 3 nodes stateless and identical, which makes load balancing behave predictably. The trade-off is that edits are per node and in memory (see [security.md](security.md)).

### Legacy build issues hit (and the fix)
| Run | Result | Issue | Fix |
|---|---|---|---|
| #112 | ❌ | `MSB3644: reference assemblies for .NETFramework,Version=v4.6.1 were not found`. The referenced helper project `eShopLegacy.Utilities` targets 4.6.1, and the windows-2022 image (`win22 20261101`) ships an incomplete 4.6.1 targeting pack | — |
| #113 | ✅ | — | `/p:TargetFrameworkVersion=v4.7.2` as a global MSBuild property: the helper is compiled for the same framework as the web app that consumes it. No project files changed; servers run 4.8 anyway |

Other legacy observations:
* The `.csproj` mixes `PackageReference` with `packages.config` / `HintPath` references. `NuGetCommand restore` on the solution handles both.
* The upstream repo is **archived**, and its `.gitignore` ignores `/deploy`, so the deploy script lives in `iis-deploy/`.
* Old dependencies with known CVEs are left as they are (no rewrites) and documented as risk.
* There was no test project, so I added `tests/eShopLegacyMVC.Tests` (MSTest, net472), approved by the interviewer.

### Changes in the fork
| File | Change |
|---|---|
| `Controllers/HealthController.cs` (+ csproj entry) | `/health`: 200 only if the catalog is readable; returns server, build, environment |
| `Views/Shared/_Layout.cshtml` | Build / env / server banner |
| `Web.config` | `BuildVersion`, `EnvironmentName` appSettings |
| `Web.Release.config` | Release hardening + `UseMockData=true` default |
| `tests/eShopLegacyMVC.Tests/**` | MSTest project |
| `iis-deploy/Deploy-IisSite.ps1` | Per-server deploy / rollback script |
| `azure-pipelines.yml` | Pipeline B |
