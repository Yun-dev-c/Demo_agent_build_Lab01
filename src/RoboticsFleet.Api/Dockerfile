FROM mcr.microsoft.com/dotnet/sdk:10.0 AS sdk
WORKDIR /src
COPY RoboticsFleet.Api.csproj ./
RUN dotnet restore
COPY . ./

FROM sdk AS migrations
RUN dotnet tool restore
ENTRYPOINT ["dotnet", "ef", "database", "update"]

FROM sdk AS build
RUN dotnet publish -c Release --no-restore -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out ./
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "RoboticsFleet.Api.dll"]
