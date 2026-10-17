import importlib.util
from pathlib import Path
import socket,threading,unittest
spec=importlib.util.spec_from_file_location('airbridge',Path(__file__).parents[1]/'host/airbridge.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class HostTests(unittest.TestCase):
 def test_fragmented_and_multiple_events(self):
  p=m.H4Events();frame=b'\x04\x0e\x04\x01\x03\x0c\x00'
  self.assertEqual(p.feed(b'\xff'+frame[:2]),[])
  self.assertEqual(p.feed(frame[2:]+frame),[frame,frame])
 def test_acl_payload_types_not_reparsed(self):
  p=m.H4Events();frame=b'\x02\x01\x00\x04\x00\x01\x02\x03\x04'
  self.assertEqual(p.feed(frame),[frame])
 def test_oversized_frame_rejected(self):
  with self.assertRaises(RuntimeError):m.H4Events().feed(b'\x02\x01\x00\xff\xff')
 def test_command_ignores_unrelated_event(self):
  a,b=socket.socketpair()
  def respond():
   self.assertEqual(b.recv(4),b'\x01\x03\x0c\x00')
   b.sendall(b'\x04\x0f\x04\x00\x01\x00\x00'+b'\x04\x0e\x04\x01\x03\x0c\x00')
  t=threading.Thread(target=respond);t.start()
  try:self.assertEqual(m.command(a.fileno(),m.H4Events(),0x0c03),b'\x04\x0e\x04\x01\x03\x0c\x00')
  finally:t.join();a.close();b.close()
 def test_no_response_timeout(self):
  a,b=socket.socketpair()
  try:
   with self.assertRaises(TimeoutError):m.command(a.fileno(),m.H4Events(),0x0c03,timeout=.01)
  finally:a.close();b.close()
 def test_hardware_error_is_not_hidden(self):
  a,b=socket.socketpair();b.sendall(b'\x04\x10\x01\x01')
  try:
   with self.assertRaisesRegex(RuntimeError,'hardware error'):m.command(a.fileno(),m.H4Events(),0x0c03)
  finally:a.close();b.close()
if __name__=='__main__':unittest.main()
