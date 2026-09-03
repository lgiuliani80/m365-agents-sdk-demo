# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
ARG NUGET_PACKAGES_REPO
ARG DEFINE_CONSTANTS

WORKDIR /src

COPY AgentFrameworkWeather.csproj ./
RUN echo "Restore NuGet packages with ${NUGET_PACKAGES_REPO:-the configured/default sources} ..." && \
    if [ -n "$NUGET_PACKAGES_REPO" ]; then \
        dotnet restore --source "$NUGET_PACKAGES_REPO" AgentFrameworkWeather.csproj; \
    else \
        dotnet restore AgentFrameworkWeather.csproj; \
    fi

COPY . ./
RUN dotnet publish AgentFrameworkWeather.csproj \
    -p:DefineConstants=${DEFINE_CONSTANTS} \
    --configuration Release \
    --output /app/publish \
    --no-restore \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app

ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_EnableDiagnostics=0

EXPOSE 8080

COPY --from=build /app/publish ./
RUN chown -R "$APP_UID:$APP_UID" /app
USER $APP_UID

ENTRYPOINT ["dotnet", "AgentFrameworkWeather.dll"]
