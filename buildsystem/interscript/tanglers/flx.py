#line 343 "lpsrc/flx_felix_tangler.pak"
#---------------------------------------------------------
# felix tangler: write to a file, insert source line numbers
# using '#line ' comments
# works for Felix
programming_language="felix"
from interscript.tanglers.base import tangler_base
import re
import string
from interscript.tokenisers.felix import felix_tokeniser
from interscript.tokenisers.felix import COMMENT, \
   MULTILINE_STRING_FIRST, \
   MULTILINE_STRING_MIDDLE, \
   MULTILINE_STRING_LAST
from interscript.tokenisers import felix_keyword
from interscript.tokenisers import felix_token

py_bracket_tokens = [
  felix_token.LPAR, felix_token.RPAR,
  felix_token.LSQB, felix_token.RSQB,
  felix_token.LBRACE, felix_token.RBRACE]

py_punct_tokens = [
  felix_token.COLON, felix_token.COMMA, felix_token.SEMI]

py_op_tokens = [
#line 371 "lpsrc/flx_felix_tangler.pak"
  ]

class flx_tangler(tangler_base):
  def __init__(self,sink,weaver,nosref=0):
    tangler_base.__init__(self,sink,weaver,nosref)
    self.matchPOD = re.compile('^ *//@(.*)$')
    self.matchcomment = re.compile('^([^/]*)//.*$')
    self.excludeid = []
    self.userdict = {}
    self.tokeniser = felix_tokeniser(report_comments = 1, split_multiline_strings=1)
    self.language = 'felix'

#  def __del__(self):
#    try:
#      tokens = self.tokeniser.close()
#    except:
#        print 'Tokeniser error'
#        try:
#          print 'closing tokeniser for',self.sink.name
#        except:
#          print 'tangler sink missing in __del__ method'
#    tangler_base.__del__(self)

  def writeline(self,data,file,count,inhibit_sref=0):
    match = self.matchPOD.match(data)
    if match:
      command = match.group(1)
      py_exec(command,file,count,globals(),self.userdict)
    else:
      self.weaver.set_fc_anchor(file,count)
      # special hack to preserve leading #! line
      if self.sink.lines_written == 0 and len(data)>2:
        inhibit_sref = data[:2]=='#!'
      self._handle_sref(file,count, inhibit_sref)
      self._writeline(data)

      tokens = self.tokeniser.tokenize(data+'\n')

      # pretty printing
      chars_written = 0
      self.weaver.start_code_line(self.sink.lines_written)
      if tokens:
        for kind,id,lstart,lend,dummy in tokens:
          first = lstart[1]
          last = lend[1]
          self.weaver.write_code_fragment(data[chars_written:first])
          markup = None
          if kind == felix_token.NAME:
            if felix_keyword.iskeyword(id): markup = 'KEYWORD'
          elif kind == COMMENT: markup = 'COMMENT'
          elif kind in [felix_token.STRING,
            MULTILINE_STRING_FIRST,
            MULTILINE_STRING_MIDDLE,
            MULTILINE_STRING_LAST]: markup = 'STRING'
          elif kind == felix_token.NUMBER: markup = 'NUMBER'
          elif kind in py_bracket_tokens : markup = 'BRACKET'
          elif kind in py_punct_tokens : markup = 'PUNCT'
          elif kind in py_op_tokens: markup = 'OP'
          self.weaver.write_code_fragment(data[first:last], markup)
          chars_written = last
        self.weaver.write_code_fragment(data[chars_written:])
      self.weaver.end_code_line()

      dst_count = self.sink.lines_written
      dst_file = self.sink.name
      class_name = 0
      function_name = 0
      level = 0
      for kind,id,lstart,lend,dummy in tokens:
        if kind is felix_token.NAME:
          if not (felix_keyword.iskeyword(id) or id in self.excludeid):
            if not self.pass_frame.ids.has_key(id): self.pass_frame.ids[id]=[]
            self.pass_frame.ids[id].append((file,count,dst_file,dst_count))
            if class_name:
              #print 'class',id
              if not self.pass_frame.classes.has_key(id): self.pass_frame.classes[id]=[]
              self.pass_frame.classes[id].append((file,count,dst_file,dst_count))
              class_name = 0
            elif function_name:
              if not self.pass_frame.functions.has_key(id): self.pass_frame.functions[id]=[]
              self.pass_frame.functions[id].append((file,count,dst_file,dst_count))
              function_name = 0
          elif id == 'class':
            class_name = 1
          elif id in ['fun','proc']:
            function_name = 1

  def write_comment(self,line,file,count):
    self.writeline('# '+line,file,count)

  def start_section(self, file, count):
    pass
    #data = '#line '+str(count)+' '+'"'+file+'"'
    #self._writeline(data)
    #if self.weaver:
    #  self.weaver.echotangle(self.sink.lines_written,data)

  def get_comment_tangler(self):
    return script_comment_tangler(self.sink)

  def get_string_tangler(self,eol,width):
    return c_string_tangler(self.sink,self.get_weaver(),eol,width)

class script_comment_tangler(tangler_base):
  def writeline(self,data,file,count,inhibit_sref=0):
    if self.weaver:
      self.weaver.writeline(data)
    self._writeline('# '+line)
