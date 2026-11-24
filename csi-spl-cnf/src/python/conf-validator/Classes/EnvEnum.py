from enum import Enum
from EnvModels import DevEnv, PrdEnv, AllEnv, LdeEnv


class ModelType(Enum):
    dev = DevEnv
    prd = PrdEnv
    all = AllEnv
    lde = LdeEnv
