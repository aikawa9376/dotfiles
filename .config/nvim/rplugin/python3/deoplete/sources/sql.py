from .base import Base
from pynvim.api.nvim import NvimError

class Source(Base):
    def __init__(self, vim):
        Base.__init__(self, vim)

        self.name = 'sw-omni'
        self.mark = '[O]'
        self.filetypes = ['sql']

    def gather_candidates(self, context):
        try:
            # カーソル下の単語を補完したい
            self.vim.call('MySqlOmniFunc', 0, '')
            self.vim.call('sqlcomplete#Map', 'syntax')
            return self.vim.call('sqlcomplete#Complete', 0, '')
        except NvimError:
            return []
