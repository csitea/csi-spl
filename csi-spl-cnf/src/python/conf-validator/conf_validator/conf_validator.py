import sys
from pydantic import ValidationError
import typer
from Classes.EnvEnum import ModelType
from rich.console import Console

app = typer.Typer()
console = Console(color_system="truecolor", width=150)
err_console = Console(stderr=True, color_system="standard", width=150)

# The exit status is a CONTRACT, not a detail. The Make target gates on this
# process's status and on nothing else —
# csi-spl-orc/src/make/generate-config-for-step.func.mk runs
# `poetry run validate … || { echo "conf-validator refused …"; exit 1; }`
# before rendering tfvars. So the one thing this program must never do is report
# "I did not check anything" as "I checked and it is fine".
#
#   0  parsed against the env's model and VALID
#   1  checked and INVALID — the errors are printed
#   2  the check COULD NOT RUN — unknown env, or the file is not there
#
# 2 used to be 0. An unknown env hit a bare `return` and a missing file a bare
# `sys.exit()`, both of which are success, so a typo'd ENV=, a wrong APP_PATH, or
# an env with no model (lde) rendered tfvars with the gate silently satisfied and
# nothing validated. A gate that cannot fail is worse than no gate: it is read as
# evidence. Pinned by csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh.
EXIT_OK = 0
EXIT_INVALID = 1
EXIT_CANNOT_CHECK = 2


@app.command()
def validate(file: str, env: str):

    try:
        model = ModelType[env].value
    except KeyError:
        known = ", ".join(member.name for member in ModelType)
        err_console.log(
            f"Invalid env: '{env}' — NOTHING WAS VALIDATED", style="deep_pink2"
        )
        err_console.log(f"Known envs: {known}", style="deep_pink2")
        err_console.log(
            "An env with no model under EnvModels/ cannot be validated. Either add "
            "EnvModels/<env>.py and register it in Classes/EnvEnum.py, or stop gating "
            "that env on this validator — do not read this as a pass.",
            style="deep_pink2",
        )
        sys.exit(EXIT_CANNOT_CHECK)

    try:
        with open(file, "r") as file_stream:
            model.parse_raw(file_stream.read())
            console.log(
                f"VALIDATED ::: {file} :white_heavy_check_mark:", style="green_yellow"
            )
    except FileNotFoundError as e:
        err_console.log(e, style="deep_pink2")
        err_console.log(
            f"NOTHING WAS VALIDATED: {file} does not exist", style="deep_pink2"
        )
        sys.exit(EXIT_CANNOT_CHECK)
    except ValidationError as e:
        err_console.log(file, style="deep_pink2")
        err_console.print("A validation error occured :x:", style="deep_pink2")
        for error in e.errors():
            err_console.log(error["loc"], style="deep_pink2")
            err_console.log(error["msg"], style="deep_pink2")
        sys.exit(EXIT_INVALID)


if __name__ == "__main__":
    app()
