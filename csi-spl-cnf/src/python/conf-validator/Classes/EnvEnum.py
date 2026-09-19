from enum import Enum
from EnvModels import DevEnv, PrdEnv, AllEnv


class ModelType(Enum):
    dev = DevEnv
    prd = PrdEnv
    all = AllEnv
