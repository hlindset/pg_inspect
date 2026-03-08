import Config

if Mix.env() == :test do
  config :junit_formatter,
    report_file: "pg_inspect.junit.xml",
    print_report_file: true
end
