std = 'luajit'
globals = { 'vim' }
max_line_length = 130

files['tests/'] = {
  std = '+busted',
}
