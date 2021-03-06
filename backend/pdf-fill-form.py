#! /usr/bin/python3

import sys
import getopt
import json
from PyQt5.QtCore import QFile, QIODevice
from popplerqt5 import Poppler
import tempfile
import subprocess
import os

def usage(err):
    print("USAGE: " + sys.argv[0] + " [--fill] [--print] [--out=out.pdf] {in.pdf}")
    sys.exit(err)

def get_form_fields(document):
    fields = {}
    for n in range(0, document.numPages()):
        page = document.page(n)
        for field in page.formFields():
            name = field.name()
            if field.type() == Poppler.FormField.FormText:
                fields[name] = field.text()
            elif field.type() == Poppler.FormField.FormButton:
                if field.buttonType() == Poppler.FormFieldButton.CheckBox:
                    fields[name] = field.state()
                elif field.buttonType() == Poppler.FormFieldButton.Radio:
                    # Poppler currently doesn't have a way to determine the
                    # field name of a radio button or the name of a group of
                    # radio buttons.
                    pass
    return fields

def set_form_fields(document, fields):
    for n in range(0, document.numPages()):
        page = document.page(n)
        for field in page.formFields():
            name = field.name()
            if name in fields:
                value = fields[name]
                if field.type() == Poppler.FormField.FormText:
                    if value == None:
                        value = ''
                    elif not isinstance(value, str):
                        value = str(value)
                    field.setText(value)
                elif field.type() == Poppler.FormField.FormButton:
                    if field.buttonType() == Poppler.FormFieldButton.CheckBox:
                        field.setState(value)
                    elif field.buttonType() == Poppler.FormFieldButton.Radio:
                        pass

def write_pdf(fd, document):
    converter = document.pdfConverter()
    converter.setPDFOptions(converter.pdfOptions() | Poppler.PDFConverter.WithChanges)
    qfile = QFile()
    qfile.open(fd, QIODevice.WriteOnly)
    converter.setOutputDevice(qfile)
    if not converter.convert():
        raise IOError(converter.lastError())

def fill_one(document, fields, fp):
    set_form_fields(document, fields)
    write_pdf(fp.fileno(), document)

def main():
    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], "o:", ["fill", "print", "out="])
    except getopt.GetoptError as err:
        print(str(err))
        sys.exit(2)

    opt_fill = False
    opt_print = False
    opt_out = None
    for opt, arg in opts:
        if opt == '--fill':
            opt_fill = True
        if opt == '--print':
            opt_print = True
        if opt in ('-o', '--out'):
            opt_out = arg
    if len(args) == 0:
        usage(2)

    document = Poppler.Document.load(args[0])
    if document == None:
        sys.exit(2)

    if opt_fill:
        fields = json.load(sys.stdin)
        if opt_out == None:
            out = os.fdopen(sys.stdout.fileno(), "wb")
        else:
            out = open(opt_out, "wb")

        array = fields
        if isinstance(fields, dict):
            array = [fields]

        if len(array) == 0:
            pass
        elif len(array) == 1 and not opt_print:
            fill_one(document, array[0], out)
        else:
            orig_fields = get_form_fields(document)
            fps = []
            for fields in array:
                fp = tempfile.NamedTemporaryFile()
                fill_one(document, dict(orig_fields, **fields), fp)
                fps.append(fp)

            # Note: pdfunite wants a seekable output file, so we cannot
            # pass it sys.stdout which may be a pipe.

            tmp_out = tempfile.NamedTemporaryFile()
            fps.append(tmp_out);

            cmd = ['pdfunite']
            cmd.extend(map(lambda fp: fp.name, fps))
            subprocess.call(cmd)

            if opt_print:
                tmp2_out = tempfile.NamedTemporaryFile()
                cmd = ['pdftocairo', '-pdf', tmp_out.name, tmp2_out.name]
                subprocess.call(cmd)
                tmp_out = tmp2_out

            while True:
                chunk = tmp_out.read(16384)
                if not chunk:
                    break
                out.write(chunk)

    else:
        fields = get_form_fields(document)
        json.dump(fields, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write('\n');

if __name__ == "__main__":
    main()
